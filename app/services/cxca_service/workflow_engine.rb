# frozen_string_literal: true

require 'set'

module CXCAService
  class WorkflowEngine
    include ModelUtils

    def initialize(program:, patient:, date:)
      @patient = patient
      @program = program
      @date = date
    end

    # Retrieves the next encounter for bound patient
    def next_encounter
      state = INITIAL_STATE
      loop do
        state = next_state state
        break if state == END_STATE

        LOGGER.debug "Loading encounter type: #{state}"
        encounter_type = EncounterType.find_by(name: state)

        return encounter_type if valid_state?(state)
      end

      nil
    end

    private

    LOGGER = Rails.logger

    # Encounter types
    INITIAL_STATE = 0 # Start terminal for encounters graph
    END_STATE = 1 # End terminal for encounters graphCxCa_TEST = 'CXCA TEST'
    CXCA_RECEPTION = 'CXCA RECEPTION'
    CXCA_TEST = 'CXCA TEST'
    CXCA_SCREENING_RESULTS = 'CXCA screening result'
    APPOINTMENT = 'APPOINTMENT'
    FEEDBACK = 'CxCa REFERRAL FEEDBACK'


    # Encounters graph
    ENCOUNTER_SM = {
      INITIAL_STATE => CXCA_RECEPTION,
      CXCA_RECEPTION =>  CXCA_TEST,
      CXCA_TEST => CXCA_SCREENING_RESULTS,
      CXCA_SCREENING_RESULTS => APPOINTMENT,
      APPOINTMENT => FEEDBACK,
      FEEDBACK  => END_STATE
    }.freeze

    STATE_CONDITIONS = {
      CXCA_RECEPTION => %i[show_reception?],
      CXCA_TEST => %i[show_cxca_test?],
      CXCA_SCREENING_RESULTS => %i[show_cxca_screening_results?],
      APPOINTMENT => %i[show_appointment?]
    }.freeze

    def next_state(current_state)
      ENCOUNTER_SM[current_state]
    end

    # Check if a relevant encounter of given type exists for given patient.
    #
    # NOTE: By `relevant` above we mean encounters that matter in deciding
    # what encounter the patient should go for in this present time.
    def encounter_exists?(type)
      Encounter.where(type: type, patient: @patient)\
               .where('encounter_datetime BETWEEN ? AND ?', *TimeUtils.day_bounds(@date))\
               .exists?
    end

    def valid_state?(state)
      return false if encounter_exists?(encounter_type(state))

      (STATE_CONDITIONS[state] || []).reduce(true) do |status, condition|
        status && method(condition).call
      end
    end

    # Checks if patient has been asked any VIA related questions today
    #
    def show_cxca_test?
      return false if cxca_positive?

      encounter_type = EncounterType.find_by name: CXCA_TEST
      encounter = Encounter.joins(:type).where(
        'patient_id = ? AND encounter_type = ? AND DATE(encounter_datetime) = DATE(?)',
        @patient.patient_id, encounter_type.encounter_type_id, @date
      ).order(encounter_datetime: :desc).first

      encounter.blank?
    end

    # Check if patient has been offered VIA and results is positive
    def show_treatment?
      return false if cxca_positive?

      encounter = Encounter.joins(:type).where(
        'encounter_type.name = ? AND encounter.patient_id = ?
        AND DATE(encounter_datetime) = ?',
        VIA_TEST, @patient.patient_id, @date).order("date_created DESC")

      unless encounter.blank?
        via_result_concept_id = concept('VIA Results').concept_id
        via_positive_result_concept_id = concept('Positive').concept_id

        return encounter.first.observations.find_by(concept_id: via_result_concept_id,
          value_coded: via_positive_result_concept_id).blank? == true ? false : true
      end

      return nil
    end

    def show_appointment?
      return true
      return nil
    end

    def show_cxca_screening_results?
      encounter_type = EncounterType.find_by name: CXCA_TEST
      encounter = Encounter.joins(:type).where(
        'patient_id = ? AND encounter_type = ? AND DATE(encounter_datetime) = DATE(?)',
        @patient.patient_id, encounter_type.encounter_type_id, @date
      ).order(encounter_datetime: :desc).first

      unless encounter.blank?
        cxca_treatment_concept_id = concept('CxCa treatment').concept_id
        same_day_treatment_concept_id = concept('Same day treatment').concept_id

        return encounter.observations.find_by("concept_id = ? AND value_coded IN(?)",
          cxca_treatment_concept_id, [same_day_treatment_concept_id]).blank? == false ? true : false
      end

      return false
    end

    def referred_treatment?
      via_treatment = concept('VIA treatment').concept_id
      referral_treatment = concept('Referral').concept_id
      cryo_treatment = concept('POSITIVE CRYO').concept_id
      thermocoagulation = concept('Thermocoagulation').concept_id

      observations = Observation.where("concept_id  = ?
        AND DATE(obs_datetime) < ? AND person_id  = ?", via_treatment,
        @date, @patient.patient_id)

      unless observations.blank?
        referred_treatment = observations.find_by(value_coded: [referral_treatment,
        cryo_treatment, thermocoagulation])
        return true unless referred_treatment.blank?

      end

      return nil
    end

    def show_cancer_treatment?
      encounter_type = EncounterType.find_by name: CANCER_TREATMENT
      encounter = Encounter.joins(:type).where(
        'patient_id = ? AND encounter_type = ? AND DATE(encounter_datetime) = DATE(?)',
        @patient.patient_id, encounter_type.encounter_type_id, @date
      ).order(encounter_datetime: :desc).first

      encounter.blank?
    end

    def show_reception?
      encounter_type = EncounterType.find_by name: CXCA_RECEPTION
      encounter = Encounter.joins(:type).where(
        'patient_id = ? AND encounter_type = ? AND DATE(encounter_datetime) = DATE(?)',
        @patient.patient_id, encounter_type.encounter_type_id, @date
      ).order(encounter_datetime: :desc).first

      encounter.blank?
    end

    private

    def cxca_positive?
      encounter_type = EncounterType.find_by name: CXCA_TEST
      encounter = Encounter.joins(:type).where(
        'patient_id = ? AND encounter_type = ? AND DATE(encounter_datetime) < DATE(?)',
        @patient.patient_id, encounter_type.encounter_type_id, @date
      ).order(encounter_datetime: :desc).first

      unless encounter.blank?
        via_result_concept_id = concept('VIA Results').concept_id
        via_positive_result_concept_id = concept('Positive').concept_id

        return encounter.observations.find_by("concept_id = ? AND value_coded IN(?)",
          via_result_concept_id, [via_positive_result_concept_id]).blank? == true ? false : true
      end

      return false
    end

    def concept(name)
      ConceptName.find_by_name(name)
    end

  end
end
