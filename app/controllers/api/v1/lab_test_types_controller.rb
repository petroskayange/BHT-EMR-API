# frozen_string_literal: true

class Api::V1::LabTestTypesController < ApplicationController
  def index
    query = engine.types search_string: params[:search_string],
                         panel_id: params[:panel_id]
    render json: paginate(query)
  end

  def panels
    query = engine.panels search_string: params[:search_string]
    render json: paginate(query)
  end

  private

  def engine
    program_id = params[:program_id]
    @engine ||= LabTestService.load_engine(program_id)
  end
end