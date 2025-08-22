# app/controllers/api/v1/status_controller.rb
# Simple status controller that bypasses all authentication
module Api
  module V1
    class StatusController < ActionController::API
      # Skip all ApplicationController filters and authentication
      # This controller inherits directly from ActionController::API
      
      def ping
        render json: {
          status: 'success',
          message: 'Server is running',
          timestamp: Time.current.iso8601,
          environment: Rails.env,
          rails_version: Rails.version,
          ruby_version: RUBY_VERSION
        }, status: :ok
      end
    end
  end
end