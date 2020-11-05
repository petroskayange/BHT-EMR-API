# frozen_string_literal: true

require_relative '../nlims'

require 'auto12epl'

class ARTService::LabTestsEngine
  include ModelUtils

  ORDERING_FACILITY = ''

  def initialize(program:)
    @program = program
  end

  ##
  # Retrieves a test type by its concept id
  def type(type_id)
    type = ConceptSet.find_members_by_name('Test type')
                     .where(concept_id: type_id)
                     .first

    unless type
      raise NotFoundError, "Test type with ID ##{type_id} does not exist"
    end

    ConceptName.find_by_concept_id!(type.concept_id)
  end

  ##
  # Search for test types by name
  def types(name: nil, specimen_type: nil)
    test_types = ConceptSet.find_members_by_name('Test type')
    test_types = test_types.filter_members(name: name) if name

    unless specimen_type
      return ConceptName.where(concept_id: test_types.select(:concept_id))
    end

    # Filter out only those test types that have the specified specimen
    # type.
    specimen_types = ConceptSet.find_members_by_name('Specimen type')
                               .filter_members(name: specimen_type)
                               .select(:concept_id)

    concept_set = ConceptSet.where(
      concept_id: specimen_types,
      concept_set: test_types
    )

    ConceptName.where(concept_id: concept_set.select(:concept_set))
  end

  def lab_locations
    nlims.locations
  end

  def labs
    nlims.labs
  end

  ##
  # Retrieve sample types by name
  def panels(name: nil, test_type: nil)
    specimen_types = ConceptSet.find_members_by_name('Specimen type')
    specimen_types = specimen_types.filter_members(name: name) if name

    unless test_type
      return ConceptName.where(concept_id: specimen_types.select(:concept_id))
    end

    # Retrieve only those specimen types that belong to concept
    # set of the selected test_type
    test_types = ConceptSet.find_members_by_name('Test type')
                           .filter_members(name: test_type)
                           .select(:concept_id)

    concept_set = ConceptSet.where(
      concept_id: specimen_types.select(:concept_id),
      concept_set: test_types
    )

    ConceptName.where(concept_id: concept_set.select(:concept_id))
  end

  # def results(accession_number)
  #   LabParameter.joins(:lab_sample)\
  #               .where('Lab_Sample.AccessionNum = ?', accession_number)\
  #               .order(Arel.sql('DATE(Lab_Sample.TimeStamp) DESC'))
  # end

  def orders_without_results(patient)
    npid = patient.identifier('National id')&.identifier
    raise InvalidParameterError, 'Patient does not have an NPID' unless npid

    nlims.tests_without_results(npid)
  rescue LimsError => e
    return [] if e.message.include?('no test pending for results')

    raise e
  end

  def test_measures(test_name)
    nlims.test_measures(test_name)
  end

  def create_external_order(patient, accession_number, date)
    ActiveRecord::Base.transaction do
      encounter = find_lab_encounter(patient, date)
      create_local_order(patient, encounter, date, accession_number)
    end
  end

  def order_test(encounter:, date:, order_params:)
    date ||= Date.today
    encounter ||= find_encounter(order_params[:patient_id], date)

    order = Order.create!(patient_id: encounter.patient_id,
                          start_date: date,
                          orderer: order_params[:orderer_id] || User.current.user_id,
                          type: OrderType.find_by_name!('Lab order'))


  end

  def create_legacy_order(patient, order)
    date_sample_drawn = order['date_sample_drawn'].to_date
    reason_for_test = order['reason_for_test']

    lims_order = nlims.legacy_order_test(patient, order)

    encounter = find_lab_encounter(patient, date_sample_drawn)
    local_order = create_local_order(patient, encounter, date_sample_drawn, lims_order['tracking_number'])
    save_reason_for_test(encounter, local_order, reason_for_test)

    { order: local_order, lims_order: lims_order }
  end

  def print_order_label(accession_number)
    order = Order.find_by_accession_number(accession_number)
    raise NotFoundError, "Order ##{accession_number} not found" unless order

    lims_order = nlims.patient_orders(accession_number)
    priority = lims_order['other']['priority']
    test = lims_order['tests'].first[0] # Pick any test name from the tests
    collector = ''
    patient = Person.find(order.patient_id)
    patient_name = PersonName.find_by_person_id(order.patient_id)

    # NOTE: The arguments are passed into the method below not in the order
    #       the method expects (eg patient_id is passed to middle_name field)
    #       to retain compatibility with labels generated by the `lab test controller`
    #       application of the NLIMS suite.
    auto12epl.generate_epl(patient_name.given_name, patient_name.family_name, order.patient_id.to_s,
                           patient.birthdate.to_s, '', patient.gender, '', collector, '', test,
                           priority, accession_number.to_s, accession_number)
  end

  def find_orders_by_patient(patient, paginate_func: nil)
    local_orders = local_orders(patient)
    local_orders = paginate_func.call(local_orders) if paginate_func
    local_orders.each_with_object([]) do |local_order, collected_orders|
      next unless local_order.accession_number

      orders = find_orders_by_accession_number local_order.accession_number
      collected_orders.push(*orders)
    rescue LimsError => e
      Rails.logger.error("Error finding LIMS order: #{e}")
    end
  end

  def find_orders_by_accession_number(accession_number)
    order = nlims.patient_orders(accession_number)
    begin
      result = nlims.patient_results(accession_number)['results']
    rescue StandardError => e
      raise e unless e.message.include?('results not available')

      result = {}
    end

    [{
      sample_type: order['other']['sample_type'],
      date_ordered: order['other']['date_created'],
      order_location: order['other']['order_location'],
      specimen_status: order['other']['specimen_status'],
      accession_number: accession_number,
      tests: order['tests'].collect do |k, v|
        test_values = result[k]&.collect do |indicator, value|
          { indicator: indicator, value: value }
        end || []

        { test_type: k, test_status: v, test_values: test_values }
      end
    }]
  end

  def save_result(data)
    nlims.update_test(data)
  end

  private

  # Creates an Order in the primary openmrs database
  def create_local_order(patient, encounter, date, accession_number)
    Order.create(patient: patient,
                 encounter: encounter,
                 concept: concept('Laboratory tests ordered'),
                 order_type: order_type('Lab'),
                 orderer: User.current.user_id,
                 start_date: date,
                 accession_number: accession_number,
                 provider: User.current)
  end

  def save_reason_for_test(encounter, order, reason)
    Observation.create(order: order,
                       encounter: encounter,
                       concept: concept('Reason for test'),
                       obs_datetime: encounter.encounter_datetime,
                       person: encounter.patient.person,
                       value_text: reason)
  end

  def find_lab_encounter(patient, date)
    start_time, end_time = TimeUtils.day_bounds(date)
    encounter = Encounter.where(patient: patient, program: @program)\
                         .where('encounter_datetime BETWEEN ? AND ?', start_time, end_time)\
                         .last
    return encounter if encounter

    Encounter.create(patient: patient, program: @program, type: encounter_type('Lab'),
                     provider: User.current.person,
                     encounter_datetime: TimeUtils.retro_timestamp(date))
  end

  def local_orders(patient)
    Order.where patient: patient,
                order_type: order_type('Lab'),
                concept: concept('Laboratory tests ordered')
  end

  def specimen_types_concept_set(name: nil)
    set = ConceptSet.find_members_by_name('Specimen type')

    if name
      search_filter = ConceptName.where('name LIKE ?', "#{search_string}%").select(:concept_id)
      set = set.where(concept: search_filter)
    end

    set
  end

  def test_types_concept_set(name: nil)
    set = ConceptSet.find_members_by_name('Test type')

    if name
      search_filter = ConceptName.where('name LIKE ?', "#{search_string}%")
    end
  end

  def nlims
    @nlims ||= ::NLims.instance
  end

  def auto12epl
    @auto12epl ||= Auto12Epl.new
  end
end
