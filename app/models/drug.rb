# frozen_string_literal: true

class Drug < ActiveRecord::Base
  self.table_name = :drug
  self.primary_key = :drug_id

  belongs_to :concept
  belongs_to :form, foreign_key: 'dosage_form', class_name: 'Concept'

  has_one :drug_cms, foreign_key: :drug_inventory_id
  has_many :barcodes, class_name: 'DrugOrderBarcode'
  has_many :alternative_names, class_name: 'AlternativeDrugName', foreign_key: 'drug_inventory_id'
  has_many :ntp_regimens, class_name: 'NtpRegimen'

  def as_json(options = {})
    super(options.merge(
      include: {
        alternative_names: {},
        barcodes: {}
      }
    ))
  end

  def arv?
    Drug.arv_drugs.map(&:concept_id).include?(concept_id)
  end

  def self.arv_drugs
    arv_concept = ConceptName.find_by(name: 'ANTIRETROVIRAL DRUGS').concept_id
    concepts = ConceptSet.where('concept_set = ?', arv_concept).map(&:concept_id)
    concepts_placeholders = '(' + (['?'] * concepts.size).join(', ') + ')'
    Drug.where("concept_id in #{concepts_placeholders}", *concepts)
  end

  def tb_drug?
    Drug.tb_drugs.map(&:concept_id).include?(concept_id)
  end

  def self.tb_drugs
    tb_concept = Concept.joins(:concept_names).where(concept_name: { name: ['Rifampicin isoniazid and pyrazinamide', 'Ethambutol', 'Rifampicin and isoniazid', 'Rifampicin Isoniazid Pyrazinamide Ethambutol'] } )
    drugs = Drug.where(concept: tb_concept)
    drugs
  end

end
