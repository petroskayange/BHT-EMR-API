# frozen_string_literal: true

require 'require_params'

class ApplicationController < ActionController::API
  include RequireParams

  def check_if_token_valid
    if params[:token]

      status = UserService.check_token(params[:token])
      if status == true
       User.current = User.where(authentication_token: params[:token]).first
       return true
      else
        response = {
            status: 401,
            error: true,
            message: 'invalid_token',
            data: {

              }
        }
      end

    else
      response = {
          status: 401,
          error: true,
          message: 'token not provided',
          data: {

      }
      }
    end

    render json: response and return
  end
end
