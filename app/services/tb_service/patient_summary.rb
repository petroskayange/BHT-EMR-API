# frozen_string_literal: true

module TBService
    # Provides various summary statistics for an TB patient
    class PatientSummary
      NPID_TYPE = 'National id'
      FILING_NUMBER = 'Filing number'
      ARCHIVED_FILING_NUMBER = 'Archived filing number'
  
      SECONDS_IN_MONTH = 2_592_000
  
      include ModelUtils
  
      attr_reader :patient
      attr_reader :date
  
      def initialize(patient, date)
        @patient = patient
        @date = date
      end
  
      def full_summary
        drug_start_date, drug_duration = drug_period
        {
          patient_id: patient.patient_id,
          npid: identifier(NPID_TYPE) || 'N/A',
          filing_number: filing_number || 'N/A',
          current_outcome: current_outcome || 'N/A',
          current_drugs: current_drugs,
					residence: residence,
          drug_duration: drug_duration || 'N/A', 
          drug_start_date: drug_start_date&.strftime('%d/%m/%Y') || 'N/A'
        }
				
      end
  
      def identifier(identifier_type_name)
        identifier_type = PatientIdentifierType.find_by_name(identifier_type_name)
  
        PatientIdentifier.where(
          identifier_type: identifier_type.patient_identifier_type_id,
          patient_id: patient.patient_id
        ).first&.identifier
      end
  
      def residence
        address = patient.person.addresses[0]
        return 'N/A' unless address
  
        district = address.state_province || 'Unknown District'
        village = address.city_village || 'Unknown Village'
        "#{district}, #{village}"
      end

      def current_drugs
        prescribe_drugs = Observation.where(person_id: patient.patient_id,
                                            concept: concept('Prescribe drugs'),
                                            value_coded: concept('Yes').concept_id)\
                                     .where('obs_datetime BETWEEN ? AND ?', *TimeUtils.day_bounds(date))
                                     .order(obs_datetime: :desc)
                                     .first
  
        return {} unless prescribe_drugs
  
        tb_extras_concepts = [concept('Rifampicin isoniazid and pyrazinamide'), concept('Ethambutol'), concept('Rifampicin and isoniazid'), concept('Rifampicin Isoniazid Pyrazinamide Ethambutol')] #add TB concepts
  
        orders = Observation.where(concept: concept('Medication orders'),
                                   person: patient.person)
                            .where('obs_datetime BETWEEN ? AND ?', *TimeUtils.day_bounds(date))
  
        orders.each_with_object({}) do |order, dosages|
          next unless order.value_coded # Raise a warning here
  
          drug_concept = Concept.find_by(concept_id: order.value_coded)
          unless drug_concept
            Rails.logger.warn "Couldn't find drug concept using value_coded ##{order.value_coded} of order ##{order.order_id}"
            next
          end
  
          next unless tb_extras_concepts.include?(drug_concept)
  
         
          drugs = Drug.where(concept: drug_concept)
  
  
          
          ingredients = NtpRegimen.where(drug: drugs)\
                                            .where('CAST(min_weight AS DECIMAL(4, 1)) <= :weight
                                                    AND CAST(max_weight AS DECIMAL(4, 1)) >= :weight',
                                                   weight: patient.weight.to_f.round(1))
          ingredients
  
          ingredients.each do |ingredient|
            drug = Drug.find_by(drug_id: ingredient.drug_id)
            dosages["drug_name"] = drug.name
          end
        end
      end
	
      def current_outcome 
        patient_id = ActiveRecord::Base.connection.quote(patient.patient_id)
        quoted_date = ActiveRecord::Base.connection.quote(date)
        program_id = Program.find_by(name: 'TB PROGRAM').program_id
        patient_state = PatientState.joins(`INNER JOIN patient_program p ON p.patient_program_id = patient_state.patient_program_id 
                                            AND p.program_id = #{program_id} WHERE (patient_state.voided = 0 AND p.voided = 0 
                                            AND p.program_id = #{program_id} AND DATE(start_date) <= visit_date AND p.patient_id = #{patient_id}) 
                                            AND (patient_state.voided = 0) ORDER BY start_date DESC, patient_state.patient_state_id DESC, 
                                            patient_state.date_created DESC LIMIT 1`).first
        return nil unless patient_state
        
        program_workflow_state = ProgramWorkflowState.find_by(program_workflow_state_id: patient_state.state)
        concept = ConceptName.find_by(concept_id: program_workflow_state.concept_id)
        concept.name

      end
  
      def drug_period 
        start_date = (recent_value_datetime('TB drug start date')\
                      || recent_value_datetime('Drug start date'))
  
        return [nil, nil] unless start_date
  
        duration = ((Time.now - start_date) / SECONDS_IN_MONTH).to_i # Round off to preceeding integer
        [start_date, duration] # Reformat date
      end
  
      # Returns the most recent value_datetime for patient's observations of the
      # given concept
      def recent_value_datetime(concept_name)
        concept = ConceptName.find_by_name(concept_name)
        date = Observation.where(concept_id: concept.concept_id,
                                 person_id: patient.patient_id)\
                          .order(obs_datetime: :desc)\
                          .first\
                          &.value_datetime
        return nil if date.blank?
  
        date
      end

      def filing_number
        filing_number = identifier(FILING_NUMBER)
        return { number: filing_number || 'N/A', type: FILING_NUMBER } if filing_number
  
        filing_number = identifier(ARCHIVED_FILING_NUMBER)
        return { number: filing_number, type: ARCHIVED_FILING_NUMBER } if filing_number
  
        { number: 'N/A', type: 'N/A' }
      end
      
    end
  end
