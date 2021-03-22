# frozen_string_literal: true

class Api::V1::CervicalCancerScreeningController < ApplicationController
  # GET /api/v1/cervical_cancer_screening
  #
  # Returns a report for patient's cervical cancer screening
  def show
    render json: service.report(patient, params[:date]&.to_date || Date.today)
  end

  private

  def patient
    Patient.find(params[:patient_id])
  end

  def service
    CervicalCancerScreeningService.new
  end
end

