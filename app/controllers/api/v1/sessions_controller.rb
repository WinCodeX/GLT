# app/controllers/api/v1/sessions_controller.rb
module Api
  module V1
    class SessionsController < Devise::SessionsController
      respond_to :json

      private

      def respond_with(resource, _opts = {})
        render json: { message: 'Logged in.', user: resource }, status: :ok
      end

      def respond_to_on_destroy
        render json: { message: "Logged out." }, status: :ok
      end
    end
  end
end