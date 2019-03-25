class Api::V1::ReportsController < ApplicationController
  def index
    date = params.require %i[date]
    stats = service.dashboard_stats(date.first)

    if stats
      render json: stats
    else
      render status: :no_content
    end
  end

  def with_nids
    stats = service.with_nids
    render json: stats
  end

  def diagnosis
    start_date, end_date = params.require %i[start_date end_date]
    stats = service.diagnosis(start_date, end_date)

    render json: stats
  end

  def registration
    start_date, end_date = params.require %i[start_date end_date]
    stats = service.registration(start_date, end_date)

    render json: stats
  end

  def diagnosis_by_address
    start_date, end_date = params.require %i[start_date end_date]
    stats = service.diagnosis_by_address(start_date, end_date)

    render json: stats
  end
  
  def cohort_report_raw_data
    limit, limit2 = params.require %i[limit limit2]
    stats = service.cohort_report_raw_data(limit, limit2)

    render json: stats
  end

  def cohort_disaggregated
    quarter, age_group = params.require %i[quarter age_group]
    stats = service.cohort_disaggregated(quarter, age_group)

    render json: stats
  end

  def drugs_given_without_prescription
    start_date, end_date = params.require %i[start_date end_date]
    stats = service.drugs_given_without_prescription(start_date, end_date)

    render json: stats
  end
  
  def drugs_given_with_prescription
    start_date, end_date = params.require %i[start_date end_date]
    stats = service.drugs_given_with_prescription(start_date, end_date)

    render json: stats
  end
  
  private

  def service
    return @service if @service

    program_id, date = params.require %i[program_id date]

    @service = ReportService.new program_id: program_id
    @service
  end
end