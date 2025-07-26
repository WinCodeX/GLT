# app/controllers/api/v1/sessions_controller.rb
module Api
  module V1
    class SessionsController < Devise::SessionsController
      respond_to :json

      private

      def respond_with(resource, _opts = {})
        token = request.env['warden-jwt_auth.token']
        response.set_header('Authorization', "Bearer #{token}") if token

        render json: {
          message: "Logged in.",
        token: token,
          user: {
            id: resource.id,
            email: resource.email,
            roles: resource.roles.pluck(:name)
          }
        }, status: :ok
      end

      def respond_to_on_destroy
        render json: { message: "Logged out." }, status: :ok
      end
    end
  end
end