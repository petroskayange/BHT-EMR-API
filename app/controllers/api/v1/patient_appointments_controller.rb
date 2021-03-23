# frozen_string_literal: true

class Api::V1::PatientAppointmentsController < ApplicationController
  def next_appointment_date
    appointment_date = service.next_appointment_date
    if appointment_date
      render json: appointment_date
    else
      render status: :not_found
    end
  end

  protected

  def service
    return @service if @service

    program_id, program_patient_id, date = appointment_params
    @service = AppointmentService.new program_id: program_id, patient_id: program_patient_id, retro_date: date

    @service
  end

  def appointment_params
    params.require([:program_id, :program_patient_id, :date])
  end
end