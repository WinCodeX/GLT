# app/controllers/api/v1/status_controller.rb
class Api::V1::StatusController < ApplicationController
  def ping
    render json: { ok: true }, status: :ok
  end
end