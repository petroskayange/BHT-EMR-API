# frozen_string_literal: true

class PatientIdentifierType < ActiveRecord::Base
  self.table_name = :patient_identifier_type
  self.primary_key = :patient_identifier_type_id

  def next_identifier(options = {})
    return nil unless options[:patient] && name == 'National id'

    new_national_id = use_moh_national_id ? new_national_id : new_v1_id

    patient_identifier = PatientIdentifier.new
    patient_identifier.type = self
    patient_identifier.identifier = new_national_id
    patient_identifier.patient = options[:patient]
    patient_identifier.save!
    patient_identifier
  end

  private

  def use_moh_national_id
    property = GlobalProperty.find_by_property('use.moh.national.id')
    property.property_value == 'yes'
  rescue StandardError => e
    Rails.logger.error "Suppressed error: #{e}"
    false
  end

  def new_national_id
    NationalId.next_id(options[:patient].patient_id)
  end

  def new_v1_id
    id_prefix = v1_id_prefix
    next_number = (last_id_number(id_prefix)[5..-2].to_i + 1).to_s.rjust(7, '0')
    new_national_id_no_check_digit = "#{id_prefix}#{next_number}"
    check_digit = PatientIdentifier.calculate_checkdigit(
      new_national_id_no_check_digit[1..-1]
    )
    "#{new_national_id_no_check_digit}#{check_digit}"
  end

  def v1_id_prefix
    health_center_id = Location.current_location.site_id.rjust 3, '0'
    "P1#{health_center_id}"
  end

  def last_id_number(id_prefix)
    PatientIdentifier.first(
      order: 'identifier desc',
      conditions: [
        'identifier_type = ? AND left(identifier, 5) = ?',
        patient_identifier_type_id,
        id_prefix
      ]
    ).number
  rescue StandardError => e
    Rails.logger.warn "Suppressed error #{e}"
    '0'
  end
end
