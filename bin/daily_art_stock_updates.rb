# frozen_string_literal: true

require 'logger'

class << self
  include ModelUtils
end

LOGGER = Logger.new(STDOUT)
ActiveRecord::Base.logger = LOGGER

def main
  debits_offset, credits_offset = read_timestamps
  process_debits(debits_offset)
  process_credits(credits_offset)
  save_timestamps(debits_offset, credits_offset)
end

def process_debits(date)
  LOGGER.debug('Processing ART stock debits (dispensations)')
  dispensations(date).reduce do |_accumulator, dispensation|
    login_as(dispensation.creator, at: dispensation.location_id)
    stock_service.update_batch_items(StockManagementService::STOCK_DEBIT,
                                     dispensation.value_drug,
                                     dispensation.value_numeric,
                                     dispensation.obs_datetime.to_date)

    dispensation.date_created # Capture the very last date
  end
end

# Credits are simply just voids
def process_credits(date)
  LOGGER.debug('Processing ART stock credits (voided dispensations)')
  voided_dispensations(date).reduce do |_accumulator, dispensation|
    next if dispensation.date_voided.to_date == dispensation.date_created.to_date

    login_as(dispensation.creator, at: dispensation.location_id)
    stock_service.update_batch_items(StockManagementService::STOCK_ADD,
                                     dispensation.value_drug,
                                     dispensation.value_numeric,
                                     dispensation.obs_datetime.to_date)

    dispensation.date_voided # Capture the very last date
  end
end

def dispensations(date)
  Observation.where('concept_id = ? AND date_created >= ?',
                    concept_name_to_id('Amount dispensed'), date)\
             .order(:date_created)
end

def voided_dispensations(date)
  Observation.unscoped\
             .where('concept_id = ? AND date_voided > ?',
                    concept_name_to_id('Amount dispensed'), date)\
             .order(:date_voided)
end

def stock_service
  StockManagementService.new
end

def login_as(user_id, at: nil)
  at ||= current_location_id

  User.current = User.find(user_id)
  Location.current = Location.find(at)
end

def current_location_id
  value = global_property('current_health_center_id')&.property_value
  raise 'Global property `current_health_center_id` not set' unless value

  value
end

OFFSETS_FILE = Rails.root.join('log', 'ART-stock-timestamps.yml')

def read_timestamps
  File.open(OFFSETS_FILE) do |fin|
    timestamps = YAML.load(fin.read)
    [timestamps[:debits_timestamp], timestamps[:credits_timestamp]]
  end
rescue StandardError => e
  LOGGER.debug("#{OFFSETS_FILE} not found: #{e} - #{e.message}")
  [Date.today.to_time, Date.today.to_time]
end

def save_timestamps(debits_timestamp, credits_timestamp)
  File.open(Rails.root.join(OFFSETS_FILE), 'w') do |fout|
    fout.write({ debits_timestamp: debits_timestamp,
                 credits_timestamp: credits_timestamp }.to_yaml)
  end
end

main
