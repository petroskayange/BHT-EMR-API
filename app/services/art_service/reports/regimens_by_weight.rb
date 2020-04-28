# frozen_string_literal: true

module ARTService
  module Reports
    Constants = ARTService::Constants

    class RegimensByWeight
      attr_reader :start_date, :end_date

      def initialize(start_date:, end_date:, **_kwargs)
        @start_date = start_date
        @end_date = end_date
      end

      def find_report
        regimen_counts
      end

      private

      WEIGHT_BANDS = [
        [3, 3.9],
        [4, 4.9],
        [6, 9.9],
        [10, 13.9],
        [14, 19.9],
        [20, 24.9],
        [25, 29.9],
        [30, 34.9],
        [35, 39.9],
        [40, Float::INFINITY],
      ].freeze

      def regimen_counts
        WEIGHT_BANDS.map do |start_weight, end_weight|
          {
            weight: weight_band_to_string(start_weight, end_weight),
            regimens: regimen_counts_by_weight(start_weight, end_weight)
          }
        end
      end

      def weight_band_to_string(start_weight, end_weight)
        if end_weight == Float::INFINITY
          "#{start_weight} Kg +"
        else
          "#{start_weight} - #{end_weight} Kg"
        end
      end

      def regimen_counts_by_weight(start_weight, end_weight)
        date = ActiveRecord::Base.connection.quote(end_date)

        Person.select("patient_current_regimen(person_id, #{date}) as regimen, count(*) AS count")
              .where(person_id: patients_in_weight_band(start_weight, end_weight))
              .group(:regimen)
              .collect { |obs| { obs.regimen => obs.count } }
      end

      def patients_in_weight_band(start_weight, end_weight)
        Observation.where(person_id: PatientsOnTreatment.within(start_date, end_date),
                          concept_id: ConceptName.where(name: 'Weight (kg)').select(:concept_id),
                          value_numeric: (start_weight...end_weight))
                   .group(:person_id)
                   .select(:person_id)
      end
    end
  end
end
