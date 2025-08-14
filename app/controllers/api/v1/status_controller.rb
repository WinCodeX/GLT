# app/controllers/api/v1/status_controller.rb
module Api
  module V1
    class StatusController < ApplicationController
      skip_before_action :authenticate_user!, only: [:ping, :health]
      before_action :force_json_format

      # Simple ping endpoint for connectivity checks
      def ping
        render json: {
          success: true,
          message: 'pong',
          timestamp: Time.current.iso8601,
          server_time: Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')
        }
      end

      # Basic health check
      def health
        begin
          # Check database connection
          ActiveRecord::Base.connection.execute('SELECT 1')
          
          render json: {
            success: true,
            status: 'healthy',
            timestamp: Time.current.iso8601,
            services: {
              database: 'ok',
              rails: 'ok'
            }
          }
        rescue => e
          render json: {
            success: false,
            status: 'unhealthy',
            timestamp: Time.current.iso8601,
            error: e.message,
            services: {
              database: 'error',
              rails: 'ok'
            }
          }, status: :service_unavailable
        end
      end

      private

      def force_json_format
        request.format = :json
      end
    end
  end
end