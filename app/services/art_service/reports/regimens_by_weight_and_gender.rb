# frozen_string_literal: true

module ARTService
  module Reports
    Constants = ARTService::Constants

    class RegimensByWeightAndGender
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
        [nil, nil] # To capture all those missing weight
      ].freeze

      def regimen_counts
        WEIGHT_BANDS.map do |start_weight, end_weight|
          {
            weight: weight_band_to_string(start_weight, end_weight),
            males: regimen_counts_by_weight_and_gender(start_weight, end_weight, 'M'),
            females: regimen_counts_by_weight_and_gender(start_weight, end_weight, 'F')
          }
        end
      end

      def weight_band_to_string(start_weight, end_weight)
        if start_weight.nil? && end_weight.nil?
          'Unknown'
        elsif end_weight == Float::INFINITY
          "#{start_weight} Kg +"
        else
          "#{start_weight} - #{end_weight} Kg"
        end
      end

      # TODO: Refactor the queries in this module... Possibly
      # prefer joins over the subqueries (ie if performance becomes an
      # issue - it probably will eventually).

      def regimen_counts_by_weight_and_gender(start_weight, end_weight, gender)
        date = ActiveRecord::Base.connection.quote(end_date)

        Person.select("patient_current_regimen(person_id, #{date}) as regimen, count(*) AS count")
              .where(person_id: PatientsOnTreatment.within(start_date, end_date))
              .where(person_id: patients_in_weight_band(start_weight, end_weight))
              .where('gender LIKE ?', "#{gender}%")
              .group(:regimen)
              .collect { |obs| { obs.regimen => obs.count } }
      end

      def patients_in_weight_band(start_weight, end_weight)
        if start_weight.nil? && end_weight.nil?
          # If no weight is provided then this must be all patients without a weight observation
          return Patient.select(:patient_id)
                        .where
                        .not(patient_id: patients_with_known_weight)
                        .group(:patient_id)
        end

        patients_with_known_weight.where(value_numeric: (start_weight...end_weight))
      end

      def patients_with_known_weight
        Observation.select(:person_id)
                   .where(concept_id: ConceptName.where(name: 'Weight (kg)').select(:concept_id))
                   .where('obs_datetime < ?', end_date)
                   .group(:person_id)
      end
    end
  end
end
