# frozen_string_literal: true

class StockManagementService
  include ParameterUtils

  # Pharmacy activities (these map to pharmacy_encounter_type.name in the db)
  STOCK_ADD = 'New deliveries'
  STOCK_EDIT = 'Edited stock'
  STOCK_DEBIT = 'Tins removed'

  # Pharmacy activity properties
  REALLOCATION_DESTINATION = 'Transfer out to location'
  REALLOCATION_DRUG = 'Drug getting reallocated'

  # Pharmacy reallocation types
  STOCK_ITEM_DISPOSAL = 'Disposal'
  STOCK_ITEM_REALLOCATION = 'Reallocation'

  def process_dispensation(dispensation_id)
    dispensation = Observation.find_by(obs_id: dispensation_id)
    raise "Dispensation ##{dispensation_id} not found" unless dispensation

    debit_drug(dispensation_drug_id(dispensation),
               dispensation.value_numeric,
               dispensation.obs_datetime,
               dispensation_id: dispensation.obs_id)
  end

  def reverse_dispensation(dispensation_id)
    dispensation = Observation.unscoped.find_by(obs_id: dispensation_id, voided: true)
    raise "*Voided* dispensation ##{dispensation_id} not found" unless dispensation

    event_log = Pharmacy.unscoped.find_by(dispensation_obs_id: dispensation_id,
                                          pharmacy_encounter_type: pharmacy_event_type(STOCK_DEBIT).id)
    raise "Dispensation ##{dispensation_id} already reversed" if event_log&.voided

    amount_rejected = credit_drug(dispensation_drug_id(dispensation),
                                  dispensation.value_numeric,
                                  dispensation.obs_datetime)
    event_log&.void('Dispensation reversed')

    amount_rejected
  end

  # Add list of drugs to stock
  #
  # @param{batch_number} A batch number that came with the drugs package
  # @param{drugs} A list of structures (hashes) containing the stock items
  #               (see description below for the stock item structure).
  #
  # Inventory item structure:
  #       {
  #         drug_id: *integer      # drug_id from Drug model
  #         quantity: *double      # Amount of drugs brought in terms of the drugs atomic unit (eg pills)
  #         expiry_date: *string   # A date conforming to ISO 8601 (ie YYYY-MM-DD)
  #         delivery_date: string  # Similar to above but is not required (defaults to today if not specified)
  #       }
  def add_items_to_batch(batch_number, stock_items)
    ActiveRecord::Base.transaction do
      batch = find_or_create_batch(batch_number)

      stock_items.each_with_index do |item, i|
        drug_id = fetch_parameter(item, :drug_id)
        quantity = fetch_parameter(item, :quantity)

        delivery_date = fetch_parameter_as_date(item, :delivery_date, Date.today)
        expiry_date = fetch_parameter_as_date(item, :expiry_date)

        item = find_batch_items(pharmacy_batch_id: batch.id, drug_id: drug_id,
                                delivery_date: delivery_date, expiry_date: expiry_date).first

        if item
          # Update existing item if already in batch
          item.delivered_quantity += quantity
          item.current_quantity += quantity
          item.save
        else
          item = create_batch_item(batch, drug_id, quantity, delivery_date, expiry_date)
          validate_activerecord_object(item)
        end

        commit_transaction(item, STOCK_ADD, quantity, delivery_date)
      rescue StandardError => e
        raise e.class, "Failed to parse stock item ##{i} due to `#{e.message}`"
      end

      batch
    end
  end

  # Returns an ActiveRecord queryset for retrieving batches on record
  def find_all_batches
    PharmacyBatch.order(date_created: :desc)
  end

  def find_batch_by_batch_number(batch_number)
    batch = PharmacyBatch.find_by_batch_number(batch_number)
    raise NotFoundError, "Batch ##{batch_number} does not exist" unless batch

    batch
  end

  def find_batch_item_by_id(id)
    PharmacyBatchItem.find(id)
  end

  def find_batch_items(filters = {})
    query = PharmacyBatchItem
    query = query.where(filters) unless filters.empty?
    query.order(Arel.sql('date_created DESC, expiry_date ASC'))
  end

  def void_batch(batch_number, reason)
    batch = find_batch_by_batch_number(batch_number)
    batch.items.each { |item| item.void(reason) }
    batch.void(reason)
  end

  def edit_batch_item(batch_item_id, params)
    ActiveRecord::Base.transaction do
      item = PharmacyBatchItem.find(batch_item_id)

      if params[:current_quantity]
        diff = params[:current_quantity].to_f - item.current_quantity
        commit_transaction(item, STOCK_EDIT, diff, Date.today, update_item: false)
      end

      if params[:delivered_quantity]
        diff = params[:delivered_quantity].to_f - item.delivered_quantity
        commit_transaction(item, STOCK_EDIT, diff, Date.today, update_item: true)
      end

      unless item.update(params)
        error = InvalidParameterError.new('Failed to update batch item')
        error.model_errors = item.errors
        raise error
      end

      item
    end
  end

  def void_batch_item(batch_item_id, reason)
    item = PharmacyBatchItem.find(batch_item_id)
    item.void(reason)
  end

  def find_earliest_expiring_item(filters = {})
    item = PharmacyBatchItem.where(filters).order(expiry_date: :asc).first
    raise NotFoundError, 'No items found' unless item

    item
  end

  def reallocate_items(reallocation_code, batch_item_id, quantity, destination_location_id, date)
    ActiveRecord::Base.transaction do
      item = PharmacyBatchItem.find(batch_item_id)

      # A negative sign would result in addition of quantity thus
      # get rid of it as early as possible
      quantity = quantity.to_f.abs
      commit_transaction(item, STOCK_DEBIT, -quantity.to_f, update_item: true)
      destination = Location.find(destination_location_id)
      PharmacyBatchItemReallocation.create(reallocation_code: reallocation_code, item: item,
                                           quantity: quantity, location: destination,
                                           reallocation_type: STOCK_ITEM_REALLOCATION,
                                           date: date, date_created: Time.now, date_changed: Time.now,
                                           creator: User.current.id)
    end
  end

  def dispose_item(reallocation_code, batch_item_id, quantity, date)
    ActiveRecord::Base.transaction do
      item = PharmacyBatchItem.find(batch_item_id)
      quantity = quantity.to_f.abs
      commit_transaction(item, STOCK_DEBIT, -quantity.to_f, update_item: true)
      PharmacyBatchItemReallocation.create(reallocation_code: reallocation_code, item: item,
                                           quantity: quantity, date: date,
                                           reallocation_type: STOCK_ITEM_DISPOSAL,
                                           date_created: Time.now, date_changed: Time.now,
                                           creator: User.current.id)
    end
  end

  def update_batch_item!(batch_item, quantity)
    if quantity.negative? && batch_item.current_quantity < quantity.abs
      raise InvalidParameterError, <<~ERROR
        Debit amount (#{quantity.abs}) exceeds current quantity (#{batch_item.current_quantity}) on item ##{batch_item.id}
      ERROR
    end

    batch_item.current_quantity += quantity.to_f
    batch_item.save
    validate_activerecord_object(batch_item)

    batch_item
  end

  DAYS_IN_MONTH = 30

  # Returns stats for time to drug depletion
  def drug_consumption(drug_id)
    consumption_rate = drug_consumption_rate(drug_id)
    stock_level = drug_stock_level(drug_id)

    stock_level_in_days = consumption_rate.zero? ? DAYS_IN_MONTH : stock_level / consumption_rate
    stock_level_in_months = stock_level_in_days / DAYS_IN_MONTH

    {
      stock_level_in_months: stock_level_in_months,
      stock_level: stock_level,
      consumption_rate: drug_consumption_rate(drug_id)
    }
  end

  private

  def debit_drug(drug_id, debit_quantity, date, dispensation_id: nil)
    drugs = find_batch_items(drug_id: drug_id).where('expiry_date > ? AND current_quantity > 0', date)
                                              .order(:expiry_date)

    commit_kwargs = { update_item: true, metadata: { dispensation_obs_id: dispensation_id } }

    drugs.each do |drug|
      break if debit_quantity.zero?

      quantity = [drug.current_quantity, debit_quantity].min
      commit_transaction(drug, STOCK_DEBIT, -quantity, date, **commit_kwargs)
      debit_quantity -= quantity
    end

    debit_quantity
  end

  def credit_drug(drug_id, credit_quantity, date)
    return credit_quantity unless credit_quantity.positive?

    drugs = find_batch_items(drug_id: drug_id)
            .where('delivery_date < :date AND expiry_date > :date AND date_changed >= :date', date: date)
            .order(:expiry_date)

    # Spread the quantity being credited back among the existing drugs,
    # making sure that no drug in stock ends up having more than was
    # initially delivered. BTW: Crediting is done following First to Expire,
    # First Out (FEFO) basis.
    drugs.each do |drug|
      break if credit_quantity.zero?

      drug_deficit = drug.delivered_quantity - drug.current_quantity

      if credit_quantity > drug_deficit
        commit_transaction(drug, STOCK_ADD, drug_deficit, date, update_item: true)
        credit_quantity -= drug_deficit
      else
        commit_transaction(drug, STOCK_ADD, credit_quantity, date, update_item: true)
        credit_quantity = 0
      end
    end

    credit_quantity
  end

  def commit_transaction(batch_item, event_name, quantity, date = nil, update_item: false, metadata: {})
    ActiveRecord::Base.transaction do
      event = Pharmacy.create(type: pharmacy_event_type(event_name),
                              item: batch_item,
                              value_numeric: quantity,
                              encounter_date: date || Date.today,
                              **metadata)
      validate_activerecord_object(event)
      update_batch_item!(batch_item, quantity) if update_item

      { event: event, target_item: batch_item }
    end
  end

  def find_or_create_batch(batch_number)
    batch = PharmacyBatch.find_by_batch_number(batch_number)
    return batch if batch

    PharmacyBatch.create(batch_number: batch_number)
  end

  def create_batch_item(batch, drug_id, quantity, delivery_date, expiry_date)
    quantity = quantity.to_f

    PharmacyBatchItem.create(
      batch: batch,
      drug_id: drug_id.to_i,
      delivered_quantity: quantity,
      current_quantity: quantity,
      delivery_date: delivery_date,
      expiry_date: expiry_date
    )
  end

  def pharmacy_event_type(event_name)
    type = PharmacyEncounterType.find_by_name(event_name)
    raise NotFoundError, "Pharmacy encounter type not found: #{event_name}" unless type

    type
  end

  # Pulls a drug id from a dispensation observation
  def dispensation_drug_id(dispensation)
    dispensation.value_drug || DrugOrder.find(dispensation.order_id).drug_inventory_id
  end

  def validate_activerecord_object(object)
    return object if object.errors.empty?

    error = InvalidParameterError.new('Failed to create or save object due to bad parameters')
    error.model_errors = object.errors
    raise error
  end

  # Returns the total amount of drug currently in stock
  def drug_stock_level(drug_id, as_of_date: nil)
    as_of_date ||= Date.today
    PharmacyBatchItem.where('drug_id = ? AND expiry_date >= ?', drug_id, as_of_date)\
                     .sum(:current_quantity)
  end

  DRUG_CONSUMPTION_RATE_INTERVAL = 90 # Period in days to account for in drug consumption rate

  # Returns rate at which drug is being used up.
  def drug_consumption_rate(drug_id, as_of_date: nil)
    # TODO: Implement some sort of caching for this method
    as_of_date ||= DRUG_CONSUMPTION_RATE_INTERVAL.days.ago.to_date

    total_drugs_consumed = Pharmacy.joins(:item, :type)
                                   .where(encounter_date: as_of_date..Float::INFINITY)
                                   .merge(PharmacyBatchItem.where(drug_id: drug_id))
                                   .merge(PharmacyEncounterType.where(name: STOCK_DEBIT))
                                   .select('SUM(ABS(value_numeric)) AS count')
                                   .first
                                   &.count

    (total_drugs_consumed || 0) / (Date.today - as_of_date).to_i
  end
end
