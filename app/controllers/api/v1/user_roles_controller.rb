class Api::V1::UserRolesController < ApplicationController
  def index
    render json: service.user_roles(user)
  end

  private

  def user
    params[:user_id].nil? ? User.current : User.find(params[:user_id])
  end

  def service
    UserService
  end
end
