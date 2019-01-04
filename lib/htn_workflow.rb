# frozen_string_literal: true

class HtnWorkflow
  include ModelUtils

  def next_htn_encounter(patient, current_encounter, date)
    encounter = check_htn_workflow patient, current_encounter, date
    return encounter unless encounter.is_a?(String)

    Encounter.new name: encounter,
                  description: 'HTN temporary encounter'
  end

  private

  def check_htn_workflow(patient, task, date)
    if !task.name.match(/VITALS/i) && !task.name.match(/TREATMENT/i) && !(task.encounter_type == nil)
      return task
    end

    # This function is for managing interaction with HTN
    referred_to_clinician = (Observation.where(["person_id = ? AND voided = 0
                            AND concept_id = ? AND obs_datetime BETWEEN ? AND ?",
                                                patient.patient_id, ConceptName.find_by_name("REFER PATIENT TO CLINICIAN").concept_id,
                                                date.strftime('%Y-%m-%d 00:00:00'),
                                                date.strftime('%Y-%m-%d 23:59:59')
                                              ]).last&.answer_string&.downcase&.strip || nil) == "yes"

    referred_to_anc = (Observation.where(["person_id = ? AND voided = 0 AND concept_id = ? AND obs_datetime BETWEEN ? AND ?",
                                          patient.patient_id, ConceptName.find_by_name("REFER TO ANC").concept_id,
                                          date.strftime('%Y-%m-%d 00:00:00'),
                                          date.strftime('%Y-%m-%d 23:59:59')
                                        ]).last&.answer_string&.downcase&.strip || nil) == "yes"

    todays_encounters = patient.encounters.find_by_date(date)
    sbp_threshold = global_property("htn.systolic.threshold")&.property_value&.to_i
    dbp_threshold = get_global_property("htn.diastolic.threshold")&.property_value&.to_i
    if task.present? && task.name.present?
      #patients eligible for HTN will have their vitals taken with HTN module
      if task.name.match(/VITALS/i)
        return "htn_vitals"
      elsif task.name.match(/TREATMENT/i) || task.encounter_type == nil
        #Alert and BP mgmt for patients on HTN or with two high BP readings
        bp = patient.current_bp(patient, date)
        bp_management_done = todays_encounters.map {|e| e.name}.include?("HYPERTENSION MANAGEMENT")
        medical_history = todays_encounters.map {|e| e.name}.include?("MEDICAL HISTORY")

        #>>>>>>>>>>>>>>>>>BP INITIAL VISIT ENCOUNTER>>>>>>>>>>>>>>>>>>>>
        treatment_status_concept_id = Concept.find_by_name("TREATMENT STATUS").id
        bp_drugs_started = Observation.where(["person_id =? AND concept_id =? AND
              value_text REGEXP ?", patient.id, treatment_status_concept_id, "BP Drugs started"]).last
        transfer_obs = Observation.where(["person_id =? AND concept_id =?",
                                          patient.id, Concept.find_by_name('TRANSFERRED').id]
        ).last

        unless bp_drugs_started.blank?
          if ((!bp[0].blank? && bp[0] <= sbp_threshold) && (!bp[1].blank? && bp[1] <= dbp_threshold)) #Normal BP
            return "bp_management"
          end if transfer_obs.blank?
        end

        #>>>>>>>>>>>>>>>>>END>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

        #Check if latest BP was high for alert
        if !bp.blank? && todays_encounters.map {|e| e.name}.count("VITALS") == 1
          if !bp_management_done && !medical_history && ((!bp[0].blank? && bp[0] > sbp_threshold) || (!bp[1].blank? && bp[1] > dbp_threshold))
            return "bp_alert"
          elsif !bp_management_done && medical_history && ((!bp[0].blank? && bp[0] > sbp_threshold) || (!bp[1].blank? && bp[1] > dbp_threshold))
            if (referred_to_clinician && (current_user_roles.include?('Clinician') || current_user_roles.include?('Doctor')))
              return "bp_management"
            elsif !referred_to_clinician
              return "bp_management"
            else
              return "patient_dashboard"
            end
          end
        end
        if !bp.blank? && ((!bp[0].blank? && bp[0] > sbp_threshold) || (!bp[1].blank? && bp[1] > dbp_threshold)) && !bp_management_done
          unless referred_to_anc
            if (referred_to_clinician && (current_user_roles.include?('Clinician') || current_user_roles.include?('Doctor')))
              return "bp_management"
            elsif !referred_to_clinician
              return "bp_management"
            else
              return "patient_dashboard"
            end
          end
        end

        if !bp.blank? && !bp_management_done && patient.programs.map {|x| x.name}.include?("HYPERTENSION PROGRAM")

          plan = Observation.where(["person_id = ? AND concept_id = ? AND obs_datetime <= ?", patient.id,
                                    Concept.find_by_name('Plan').id, date.strftime('%Y-%m-%d 23:59:59')]
          ).order("obs_datetime DESC").last

          unless (plan.blank? || plan.value_text.match(/ANNUAL/i)) && !referred_to_anc
            return "bp_management"
          end
        end

        #If BP was not high, check if patient is on BP treatment. This check may be redudant
        unless referred_to_anc
          if is_patient_on_htn_treatment?(patient, date) && !bp_management_done

            if (referred_to_clinician && (current_user_roles.include?('Clinician') || current_user_roles.include?('Doctor')))
              return "bp_management"
            elsif !referred_to_clinician
              return "bp_management"
            else
              return "patient_dashboard"
            end
          end
        end
      end
    end

    task
  end

  def current_bp(patient, date = Date.today)
    encounter_id = patient.encounters.where("encounter_type = ? AND DATE(encounter_datetime) = ?",
      EncounterType.find_by_name("VITALS").id, date.to_date).last.id rescue nil

    ans = [(Observation.where("encounter_id = ? AND concept_id = ?", encounter_id,
          ConceptName.find_by_name("SYSTOLIC BLOOD PRESSURE").concept_id).last.answer_string.to_i rescue nil),
      (Observation.where("encounter_id = ? AND concept_id = ?", encounter_id,
          ConceptName.find_by_name("DIASTOLIC BLOOD PRESSURE").concept_id).last.answer_string.to_i rescue nil)
    ]
    ans = ans.reject(&:blank?)
  end
end
