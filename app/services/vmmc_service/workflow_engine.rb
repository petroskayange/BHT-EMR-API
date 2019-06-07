# frozen_string_literal: true

class VMMCService::WorkflowEngine
  include ModelUtils

  attr_reader :program, :patient

  def initialize(program:, patient:, date:)
    @program = program
    @patient = patient
    @date = date
    @user_activities = ""
    @activities = load_user_activities
  end

  def next_encounter
    # 'N/A'
    state = INITIAL_STATE
    loop do
    	state = next_state state
    	break if state == END_STATE

    	LOGGER.debug "Loading encounter type: #{state}"
    	encounter_type = EncounterType.find_by(name: state)

    	return encounter_type if valid_state?(state)
  	end
  end

  def valid_state?(state)
    # if state == POST_OP_REVIEW
    #   raise encounter_exists?(encounter_type(state)).inspect
    # end

    if encounter_exists?(encounter_type(state)) || !@activities.include?(state)
      return false
    end

    (STATE_CONDITIONS[state] || []).reduce(true) do |status, condition|
      status && method(condition).call
    end
  end

  private

  LOGGER = Rails.logger

  # Encounter types
  INITIAL_STATE = 0 # Start terminal for encounters graph
  END_STATE = 1 # End terminal for encounters graph
  REGISTRATION_CONSENT = 'REGISTRATION CONSENT'
  VITALS = 'VITALS'
  MEDICAL_HISTORY = 'MEDICAL HISTORY'
  HIV_STATUS = 'UPDATE HIV STATUS'
  GENITAL_EXAMINATION = 'GENITAL EXAMINATION'
  SUMMARY_ASSESSMENT = 'SUMMARY ASSESSMENT'
  CIRCUMCISION = 'CIRCUMCISION'
  POST_OP_REVIEW = 'POST-OP REVIEW'
  APPOINTMENT = 'APPOINTMENT'
  FOLLOW_UP = 'FOLLOW UP'

  # Encounters graph
  ENCOUNTER_SM = {
    INITIAL_STATE => REGISTRATION_CONSENT,
    REGISTRATION_CONSENT => MEDICAL_HISTORY,
    MEDICAL_HISTORY => VITALS,
    VITALS => HIV_STATUS,
    HIV_STATUS => GENITAL_EXAMINATION,
    GENITAL_EXAMINATION => SUMMARY_ASSESSMENT,
    SUMMARY_ASSESSMENT => CIRCUMCISION,
    CIRCUMCISION => POST_OP_REVIEW,
    POST_OP_REVIEW => APPOINTMENT,
    APPOINTMENT => FOLLOW_UP,
    FOLLOW_UP => END_STATE
  }.freeze

  STATE_CONDITIONS = {
    CIRCUMCISION => %i[patient_gives_consent?],
    APPOINTMENT => %i[patient_ready_for_discharge?],
    FOLLOW_UP => %i[patient_has_post_op_review_encounter?]

  }.freeze

  def load_user_activities
    activities = user_property('Activities')&.property_value
    encounters = (activities&.split(',') || []).collect do |activity|
      # Re-map activities to encounters
      case activity
      when /Registration Consent/i
        REGISTRATION_CONSENT
      when /medical history/i
        MEDICAL_HISTORY
      when /vitals/i
        VITALS
      when /hiv status/i
        HIV_STATUS
      when /genital examination/i
        GENITAL_EXAMINATION
      when /summary assessment/i
        SUMMARY_ASSESSMENT
      when /circumcision/i
        CIRCUMCISION
      when /post-op review/i
        POST_OP_REVIEW
      when /Appointment/i
        APPOINTMENT
      when /follow up/i
        FOLLOW_UP
      else
        Rails.logger.warn "Invalid VMMC activity in user properties: #{activity}"
      end
    end

    encounters
  end

  def next_state(current_state)
    ENCOUNTER_SM[current_state]
  end

  def encounter_exists?(type)
    Encounter.where(type: type, patient: @patient, program_id: vmmc_program.program_id)\
             .where('encounter_datetime BETWEEN ? AND ?', *TimeUtils.day_bounds(@date))\
             .exists?
  end

  def vmmc_program
    @vmmc_program ||= Program.find_by_name('VMMC Program')
  end

  def yes_concept
    @yes_concept ||= ConceptName.find_by_name('Yes')
  end

  def patient_gives_consent?
    consent_confirmation_concept_id = ConceptName.find_by_name('Consent Confirmation').concept_id

    Observation.joins(:encounter)\
               .where(person_id: @patient.id,
                      concept_id: consent_confirmation_concept_id,
                      value_coded: yes_concept.concept_id)\
               .merge(Encounter.where(program_id: vmmc_program.program_id))
               .exists?
  end

  def vmmc_registration_encounter_not_collected?
    encounter = Encounter.joins(:type).where(
      'encounter_type.name = ? AND encounter.patient_id = ?',
      REGISTRATION, @patient.patient_id)

    encounter.blank?
  end

  def post_op_review_encounter_not_collected?
    encounter = Encounter.joins(:type).where(
      'encounter_type.name = ? AND encounter.patient_id = ?',
      POST_OP_REVIEW, @patient.patient_id)

    encounter.blank?
  end

  def patient_ready_for_discharge?
    ready_for_discharge_concept_id = ConceptName.find_by_name('Ready for discharge?').concept_id
    yes_concept_id = ConceptName.find_by_name('Yes').concept_id

    Observation.joins(:encounter)\
               .where(concept_id: ready_for_discharge_concept_id,
                      value_coded: yes_concept_id)\
               .merge(Encounter.where(program: vmmc_program))
               .exists?
  end

    def medical_history_not_collected?

      medical_history_enc = EncounterType.find_by name: MEDICAL_HISTORY

      med_history = Encounter.where("encounter_type = ?
          AND patient_id = ? AND DATE(encounter_datetime) >= DATE(?)",
          medical_history_enc.id, @patient.patient_id, @date)
        .order(encounter_datetime: :desc).first.blank?

      med_history
    end

  def patient_tested_for_hiv?
          hiv_status_enc = EncounterType.find_by name: STATUS

      hiv_status = Encounter.where("encounter_type = ?
          AND patient_id = ? AND DATE(encounter_datetime) >= DATE(?)",
          hiv_status_enc.id, @patient.patient_id, @date)
        .order(encounter_datetime: :desc).first.blank?

      hiv_status

  end

  def patient_has_post_op_review_encounter?


  end

end
