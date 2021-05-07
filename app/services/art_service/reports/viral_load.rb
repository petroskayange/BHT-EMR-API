
class ARTService::Reports::ViralLoad
  include ModelUtils

  def initialize(start_date:, end_date:)
    @start_date = start_date.to_date.strftime('%Y-%m-%d 00:00:00')
    @end_date = end_date.to_date.strftime('%Y-%m-%d 23:59:59')
    @program = Program.find_by_name 'HIV Program'
    @possible_milestones = possible_milestones
  end

  def clients_due
    clients =  potential_get_clients
    return [] if clients.blank?
    clients_due_list = []

    clients.each do |person|
      vl_details = get_vl_due_details(person) #person[:patient_id], person[:appointment_date], person[:start_date])
      next if vl_details.blank?
      clients_due_list << vl_details
    end

    return clients_due_list
  end


  private

  def potential_get_clients
    encounter_type = EncounterType.find_by_name 'Appointment'
    appointment_concept = ConceptName.find_by_name 'Appointment date'

    observations = Observation.where("(value_datetime BETWEEN ? AND ?) AND concept_id = ?",
      @start_date, @end_date, appointment_concept.concept_id).\
      joins("INNER JOIN encounter e ON e.encounter_id = obs.encounter_id AND e.program_id=#{@program.id}
      AND encounter_type = #{encounter_type.id}
      LEFT JOIN person p ON p.person_id = obs.person_id
      LEFT JOIN person_name n ON n.person_id = obs.person_id
      LEFT JOIN patient_identifier i ON i.patient_id = e.patient_id
      AND i.voided = 0 AND i.identifier_type = 4").group("obs.person_id").\
      order(:value_datetime).select("obs.person_id, value_datetime,
      date_antiretrovirals_started(obs.person_id, patient_start_date(obs.person_id)) start_date,
      identifier, n.given_name, n.family_name, p.birthdate, p.gender")

    return observations.map do |ob|
      {
        patient_id: ob['person_id'].to_i,
        appointment_date: ob['value_datetime'],
        start_date: ob['start_date'],
        given_name: ob['given_name'],
        family_name: ob['family_name'],
        birthdate: ob['birthdate'],
        gender: ob['gender'],
        arv_number: ob['identifier']
      }
    end
  end

  def get_vl_due_details(person) #patient_id, appointment_date, patient_start_date)
    patient_start_date = person[:start_date].to_date rescue nil
    return if patient_start_date.blank?
    start_date = patient_start_date
    appointment_date = person[:appointment_date].to_date
    months_on_art = date_diff(patient_start_date.to_date, @end_date.to_date)

    if @possible_milestones.include?(months_on_art)
      return {
        patient_id: person[:patient_id],
        mile_stone: (patient_start_date.to_date + months_on_art.month).to_date,
        start_date: patient_start_date,
        months_on_art: months_on_art,
        appointment_date: appointment_date,
        given_name: person[:given_name],
        family_name: person[:family_name],
        gender: person[:gender],
        birthdate: person[:birthdate],
        arv_number: person[:arv_number]
      }
    end
  end

  def date_diff(date1, date2)
    diff_cal = ActiveRecord::Base.connection.select_one <<~SQL
    SELECT TIMESTAMPDIFF(MONTH, DATE('#{date1.to_date}'), DATE('#{date2.to_date}')) AS months;
    SQL

    return diff_cal['months'].to_i
  end

  def possible_milestones
    milestones = [6]
    start_month = 6

    1.upto(100).each do |y|
      milestones << (start_month += 12)
    end

    return milestones
  end

end