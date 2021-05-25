# frozen_string_literal: true

require 'ostruct'

module LaboratoryService
  class ReportEngine
    attr_reader :program

    LOGGER = Rails.logger

    REPORTS = {
      'SAMPLES_DRAWN' => LaboratoryService::Reports::Clinic::Orders
    }.freeze


    def samples_drawn(start_date, end_date)
      REPORTS['SAMPLES_DRAWN'].new(start_date: start_date, end_date: end_date).samples_drawn
    end

    def test_results(start_date, end_date)
      REPORTS['SAMPLES_DRAWN'].new(start_date: start_date, end_date: end_date).test_results
    end

    def orders_made(start_date, end_date, status)
      REPORTS['SAMPLES_DRAWN'].new(start_date: start_date,
        end_date: end_date).orders_made(status)
    end

  end
end