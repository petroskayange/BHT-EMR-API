require 'utils/remappable_hash'

class Api::V1::EncountersController < ApplicationController
  # Retrieve a list of encounters
  #
  # GET /encounter
  #
  # Optional parameters:
  #   patient_id: Retrieve encounters belonging to this patient
  #   location_id: Retrieve encounters at this location
  #   encounter_type_id: Retrieve encounters with this id only
  #   page, page_size: For pagination. Defaults to page 0 of size 12
  def index
    # Ignoring error value as required_params never errors when
    # retrieving optional parameters only
    filters = params.permit %i[patient_id location_id encounter_type_id date]

    if filters.empty?
      render json: paginate(Encounter)
    else
      remap_encounter_type_id! filters if filters[:encounter_type_id]
      date = filters.delete :date
      queryset = Encounter.where filters
      queryset = queryset.where 'DATE(encounter_datetime) = DATE(?)', date if date
      render json: paginate(queryset)
    end
  end

  # Generate a report on counts of various encounters
  # 
  # POST /reports/encounters
  #
  # Optional parameters:
  #    all - Retrieves all encounters not just those created by current user
  def count
    encounter_types, = params.require(%i[encounter_types])

    complete_report = encounter_types.each_with_object({}) do |type_id, report|
      male_count = count_by_gender(type_id, 'M', params[:date])
      fem_count = count_by_gender(type_id, 'F', params[:date])
      report[type_id] = { 'M': male_count, 'F': fem_count }
    end

    render json: complete_report
  end

  # Retrieve single encounter.
  #
  # GET /encounter/:id
  def show
    render json: Encounter.find(params[:id])
  end

  # Create a new Encounter
  #
  # POST /encounter
  #
  # Required parameters:
  #   encounter_type_id: Encounter's type
  #   patient_id: Patient involved in the encounter
  #
  # Optional parameters:
  #   provider_id: user_id of surrogate doing the data entry defaults to current user 
  def create
    create_params, errors = required_params required: %i[encounter_type_id patient_id],
                                            optional: %i[provider_id encounter_datetime]
    return render json: { errors: create_params }, status: :bad_request if errors

    remap_encounter_type_id! create_params
    validation_errors = validate_create_params create_params
    return render json: { errors: validation_errors } if validation_errors

    create_params[:location_id] = Location.current.id
    create_params[:provider_id] ||= User.current.id
    create_params[:creator] = User.current.id
    create_params[:encounter_datetime] ||= Time.now
    create_params[:date_created] = Time.now
    encounter = Encounter.create create_params

    return render json: encounter.errors, status: :bad_request unless encounter.errors.empty?

    render json: encounter, status: :created
  end

  # Update an existing encounter
  #
  # PUT /encounter/:id
  #
  # Optional parameters:
  #   encounter_type_id: Encounter's type
  #   patient_id: Patient involved in the encounter
  def update
    update_params, errors = required_params optional: %i[type_id patient_id]
    return render json: { errors: update_params }, status: :bad_request if errors

    remap_encounter_type_id! update_params
    validation_errors = validate_create_params update_params
    return render json: { errors: validation_errors } if validation_errors

    encounter = Encounter.update update_params
    return render json: encounter.errors, status: :bad_request if encounter.errors

    render json: encounter, status: :ok
  end

  # Void an existing encounter
  #
  # DELETE /encounter/:id
  def destroy
    encounter = Encounter.find params[:id]
    if encounter.void "Voided by #{User.current}"
      render status: :no_content
    else
      # Not supposed to happen...
      render json: encounter.errors, status: :internal_serval_error
    end
  end

  private

  def validate_create_params(params)
    encounter_type_id = params[:encounter_type_id]
    if encounter_type_id && !EncounterType.exists?(encounter_type)
      return ["Encounter type ##{encounter_type} not found"]
    end

    patient_id = params[:patient_id]
    if patient_id && !Patient.exists?(patient_id)
      return ["Patient ##{patient_id} not found"]
    end

    nil
  end

  # HACK: Have to rename encounter_type_id because in the model
  # underneath it is unfortunately named encounter_type not
  # encounter_type_id. However, we prefer to use encounter_type_id
  # when receiving input from clients to retain an orthogonal
  # interface across the API. Can't be using person_id, patient_id,
  # etc and then surprise our clients with encounter_type as another
  # form of an id.
  def remap_encounter_type_id!(hash)
    hash.remap_field! :encounter_type_id, :encounter_type
  end

  def count_by_gender(type_id, gender, date = nil)
    filters = { encounter_type: type_id }
    filters[:creator] = User.current.user_id unless params[:all]

    queryset = Encounter.where(filters)
    queryset = queryset.joins(
      'INNER JOIN person ON encounter.patient_id = person.person_id'
    ).where('person.gender = ?', gender)
    if params[:date]
      date = Date.strptime params[:date]
      queryset = queryset.where 'DATE(encounter_datetime) = DATE(?)', date
    end

    queryset.count
  end
end
