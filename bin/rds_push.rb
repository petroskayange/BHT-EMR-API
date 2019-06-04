# frozen_string_literal: true

require 'logger'
require 'rest-client'

LOGGER = Class.new do
  # The 'logger' module does not provide a logger that can log
  # to multiple streams hence rolling our own quick and dirty one.

  LOGGERS = [Logger.new(Rails.root.join('log/rds-sync.log')), Logger.new(STDOUT)].freeze

  def initialize
    LOGGERS.each do |logger|
      logger.level = Logger::DEBUG
    end
  end

  def method_missing(method_name, *args)
    LOGGERS.each { |logger| logger.method(method_name).call(*args) }
  end
end.new

# Uncomment the following to log SQL queries and CouchDB queries
# ActiveRecord::Base.logger = LOGGER
# RestClient.log = LOGGER

ActiveRecord::Base.logger = LOGGER

APPLICATION_CONFIG_PATH = Rails.root.join('config/application.yml')
DELTA_STATE_PATH = Rails.root.join('log/rds-sync-state.yml')

MODELS = [Person, PersonAttribute, PersonAddress, PersonName, User, Patient,
          PatientIdentifier, PatientState, PatientProgram, Encounter,
          Observation, Order, DrugOrder].freeze

TIME_EPOCH = '0000-00-00 00:00:00'
DEST_TIME_EPOCH = '1000-01-01 00:00:00'

# These models are missing a `date_changed` field...
# They probably are not meant to be changed after creation.
IMMUTABLE_MODELS = [PersonAddress, PatientIdentifier, Observation, Order].freeze

# Maximum number of records to be fetched from database per request
RECORDS_BATCH_SIZE = 50_000

def main(database, program_name)
  LOGGER.info("Scraping database [#{database}, #{program_name}]")
  initiate_couch_sync

  program = Program.find_by_name(program_name)

  MODELS.each do |model|
    LOGGER.debug("Scanning model: #{model}")
    last_update_time = database_offset(model, database)

    recent_records(model, last_update_time, database).each do |record|
      LOGGER.debug("Handling #{model}(##{record.id})")

      update_time = record_update_time(record)
      last_update_time = update_time if update_time > last_update_time

      sync_status = find_record_sync_status(record, database)
      if record_already_synced?(record, sync_status)
        LOGGER.debug("Skipping already synced record #{model}(##{record.id})")
        next
      end

      record_doc_id = push_record(record, sync_status&.record_doc_id, program)

      save_record_sync_status(sync_status, record, record_doc_id, database)
    rescue RestClient::Exception => e
      LOGGER.error("Failed to write #{model} ##{record.id} due to exception: #{e.class} - #{e} - #{e.response.body}")
    end

    save_database_offset(model, last_update_time, database)
  end
end

# Attempts to execute passed block with a lock file
def with_lock
  File.open('/tmp/rds_push.lock', File::RDWR | File::CREAT) do |lock_file|
    unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
      LOGGER.warn 'Another instance is already is running'
      exit 255
    end

    yield
  end
end

def database_offset(model, database)
  @database_offset ||= DELTA_STATE_PATH.exist? ? YAML.load_file(DELTA_STATE_PATH) : {}
  @database_offset["#{database}.#{model}"] || TIME_EPOCH
end

# Load database configuration
def config
  return @config if @config

  @config = YAML.load_file(APPLICATION_CONFIG_PATH)['rds']

  raise '[rds] config not found in `application.yml`' if @config.blank?

  @config
end

def save_database_offset(model, time, database)
  return if database_offset(model, database) == time

  @database_offset["#{database}.#{model}"] = time

  Dir.mkdir(DELTA_STATE_PATH.parent) unless DELTA_STATE_PATH.parent.exist?

  LOGGER.debug("Saving database_offset, #{time}, for model: #{database}.#{model}")

  File.open(DELTA_STATE_PATH, 'w') do |fin|
    fin.write(@database_offset.to_yaml)
  end
end

def recent_records(model, database_offset, database)
  Enumerator.new do |enum|
    offset = 0

    loop do
      LOGGER.info("Retrieving #{model}s from database '#{database}' having [time >= #{database_offset}, index >= #{offset}]")
      model.establish_connection(database.to_sym)

      records = if model == User
                  model.unscoped.where('date_created >= :time OR date_changed >= :time OR date_retired >= :time', time: database_offset.to_s)
                elsif immutable_model?(model)
                  # HACK: person address seems to be missing `date_changed` field so we
                  # fall back to the existing `date_created`
                  model.unscoped.where('date_created >= :time OR date_voided >= :time', time: database_offset.to_s)
                elsif model == DrugOrder
                  # DrugOrder lacks date_changed and date_created fields. We instead use
                  # the parent Order's date_created.
                  model.unscoped\
                       .joins('INNER JOIN orders ON orders.order_id = drug_order.order_id')\
                       .where('date_created >= :time OR date_voided >= :time', time: database_offset.to_s)
                else
                  model.unscoped.where('date_changed >= :time OR date_created >= :time OR date_voided >= :time', time: database_offset)
                end

      records = records.order(model.primary_key.to_s).offset(offset).limit(RECORDS_BATCH_SIZE)

      records.each { |record| enum.yield(record) }

      break if records.empty?

      offset += RECORDS_BATCH_SIZE
    end
  end
end

def model(name)
  name.constantize
end

def immutable_model?(model, instance = false)
  model = model.class if instance

  IMMUTABLE_MODELS.include?(model)
end

# Returns the last time this record was updated
def record_update_time(record)
  # HACK: Models like PersonAddress are missing the preferred
  #   `date_changed` field thus we are falling back to date_created
  if immutable_model?(record, true)
    return record_date_voided(record) || record.date_created
  end

  if record.class == DrugOrder
    order = Order.unscoped.find(record.order_id)
    return order.date_voided || order.date_created
  end

  record_date_voided(record) || record.date_changed || record.date_created
end

def record_date_voided(record)
  record.respond_to?(:date_retired) ? record.date_retired : record.date_voided
end

def find_record_sync_status(record, database)
  RecordSyncStatus.where(record_type: RecordType.find_by_name(record.class.to_s),
                         record_id: record.id,
                         database: database)\
                  .first
end

def record_already_synced?(record, sync_status)
  return false unless sync_status

  record_update_time(record) <= sync_status.updated_at
end

def save_record_sync_status(sync_status, record, record_doc_id, database)
  time = Time.now

  if sync_status
    sync_status.update(updated_at: time)
    return sync_status
  end

  RecordSyncStatus.create(
    record_type: RecordType.find_by_name(record.class.to_s),
    record_doc_id: record_doc_id,
    record_id: record.id,
    database: database,
    created_at: time,
    updated_at: time
  )
end

# Pushes a record to couch db
#
# @param {record} - An ActiveRecord object to push to CouchDB
# @param {doc_id} - An optional couch document id which if specified triggers
#                   an update of the couch document with record.
#
# @returns  - A couch document id for the pushed record
def push_record(record, doc_id = nil, program = nil)
  LOGGER.info("Pushing record to couch db: #{record.class}(##{record.id}, doc_id: #{doc_id || 'N/A'}) ")

  record = serialize_record(record, program).to_json

  if doc_id
    push_existing_record(record, doc_id)
  else
    push_new_record(record)
  end
end

# Convert record to JSON
def serialize_record(record, program)
  serialized_record = record.as_json(ignore_includes: true)
  transform_record_keys(record, serialized_record, program)

  serialized_record['record_type'] = record.class.to_s

  if record.class == Encounter && (!record.respond_to?(:program_id) || record.program_id.nil?)
    # HACK: Apparently this script may be run on old applications
    # that use the old openmrs standard that has no program
    # specific encounters. Thus we manually have to set the program
    # id using the value specified in the config file.
    raise "Invalid or missing program name '#{program&.name}' in rds config: application.yml" unless program

    serialized_record['program_id'] = program.id

    # HACK: Another hack to handle HTS program encounters
    serialized_record.delete('patient_program_id') if serialized_record.key?('patient_program_id')
  elsif [User, Person, PersonName].include?(record.class) && !record_uuid_was_remapped?(record)
    # HACK: On setup of most BHT applications, a default set of users is seeded.
    # These retain the same UUIDs across space. We need to remap these UUIDs
    # since they all will be loaded into the same database that holds unique
    # constraints on all UUID fields.
    remap = remap_record_uuid(record)
    serialized_record['uuid'] = remap.new_uuid
  end

  if record.respond_to?(:date_created) && record.date_created.blank?
    serialized_record['date_created'] = DEST_TIME_EPOCH
  end

  serialized_record
end

SITE_CODE_MAX_WIDTH = 5
PROGRAM_ID_MAX_WIDTH = 2
CURRENT_HEALTH_CENTER_ID = GlobalProperty.find_by_property('current_health_center_id')\
                                         .property_value\
                                         .to_s\
                                         .rjust(SITE_CODE_MAX_WIDTH, '0')

# Transforms primary key and foreign keys on record to the format required in RDS
def transform_record_keys(record, serialized_record, program)
  site_id = CURRENT_HEALTH_CENTER_ID

  program_id = program&.id&.to_s&.rjust(PROGRAM_ID_MAX_WIDTH, '0') || '00'

  serialized_record[record.class.primary_key.to_s] = "#{record.id}#{program_id}#{site_id}".to_i

  record.class.reflect_on_all_associations(:belongs_to).each do |association|
    next unless MODELS.include?(association.class_name.constantize)\
                  && association.foreign_key.to_s != record.class.primary_key.to_s

    id = record.send(association.foreign_key.to_sym)
    next unless id

    serialized_record[association.foreign_key.to_s] = "#{id}#{program_id}#{site_id}".to_i
  end

  serialized_record
end

def remap_record_uuid(record)
  new_uuid = ActiveRecord::Base.connection.select_one('SELECT UUID() as uuid')['uuid']
  old_uuid = record.uuid

  record.uuid = new_uuid
  model = record.class
  database = model.connection.current_database

  ActiveRecord::Base.connection.execute(
    <<~SQL
      UPDATE `#{database}`.`#{model.table_name}`
      SET uuid = '#{new_uuid}'
      WHERE #{model.primary_key} = '#{record.id}'
    SQL
  )

  UuidRemap.create(model: record.class.to_s,
                   database: record.class.connection.current_database,
                   old_uuid: old_uuid,
                   new_uuid: new_uuid,
                   record_id: record.id)
end

def record_uuid_was_remapped?(record)
  UuidRemap.where(model: record.class.to_s,
                  database: record.class.connection.current_database,
                  new_uuid: record.uuid).exists?
end

# Push a new record to couch db
#
# @see push_record
def push_new_record(record)
  handle_couch_response do
    RestClient.post(local_couch_database_url, record, content_type: :json)
  end
end

def push_existing_record(record, doc_id)
  handle_couch_response do
    RestClient.put("#{local_couch_database_url}/#{doc_id}", record, content_type: :json)
  end
end

def create_couch_database
  response = RestClient.put(local_couch_database_url, {})
  LOGGER.debug(response)
end

def local_couch_url
  couch_config = config['couchdb']['local']
  protocol = couch_config['protocol']
  username = couch_config['username']
  password = couch_config['password']
  host = couch_config['host']
  port = couch_config['port']

  "#{protocol}://#{username}:#{password}@#{host}:#{port}"
end

def local_couch_host_url
  couch_config = config['couchdb']['local']
  protocol = couch_config['protocol']
  host = couch_config['host']
  port = couch_config['port']

  "#{protocol}://#{host}:#{port}"
end

def local_couch_database_url
  "#{local_couch_url}/#{config['couchdb']['local']['database']}"
end

# Local couch url but without any auth information
def bare_local_couch_database_url
  "#{local_couch_host_url}/#{config['couchdb']['local']['database']}"
end

def master_couch_url
  couch_config = config['couchdb']['master']
  protocol = couch_config['protocol']
  username = couch_config['username']
  password = couch_config['password']
  host = couch_config['host']
  port = couch_config['port']

  "#{protocol}://#{username}:#{password}@#{host}:#{port}"
end

def master_couch_host_url
  couch_config = config['couchdb']['master']
  protocol = couch_config['protocol']
  host = couch_config['host']
  port = couch_config['port']

  "#{protocol}://#{host}:#{port}"
end

def master_couch_database_url
  "#{master_couch_url}/#{config['couchdb']['master']['database']}"
end

def bare_master_couch_database_url
  couch_config = config['couchdb']['master']
  database = couch_config['database']

  "#{master_couch_host_url}/#{database}"
end

def initiate_couch_sync
  request = {
    'source' => bare_local_couch_database_url,
    'target' => bare_master_couch_database_url,
    'continuous' => true
  }

  return if already_in_sync?(request)

  url = "#{local_couch_url}/_replicate"

  RestClient.post(url, request.to_json, content_type: :json,
                                        referer: local_couch_host_url)
end

def already_in_sync?(sync_params)
  response = RestClient.get("#{local_couch_url}/_active_tasks/replications")

  JSON.parse(response.body).each do |replication|
    LOGGER.debug([replication['source'], replication['target']])
    is_in_sync = (replication['source'].include?(sync_params['source'])\
                  && replication['target'].include?(sync_params['target']))

    next unless is_in_sync

    LOGGER.debug('Replication job already running in CouchDB')
    return true
  end

  false
end

# Handle response from couch db
def handle_couch_response
  response = JSON.parse(yield)
  response['id']
rescue RestClient::NotFound => e
  reason = JSON.parse(e.response.body)['reason']

  if reason.casecmp?('Database does not exist.')
    create_couch_database
    retry
  end

  raise e
end

if $PROGRAM_NAME == __FILE__ # HACK: Enables importing of this as a module
  with_lock do
    config # Load configuration early to ensure its sanity before doing anything

    config['databases'].each do |database, database_config|
      main(database, database_config['program&.name'])
    end
  end
end
