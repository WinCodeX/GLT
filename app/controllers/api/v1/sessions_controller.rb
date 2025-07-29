# app/controllers/api/v1/sessions_controller.rb
module Api
  module V1
    class SessionsController < Devise::SessionsController
      respond_to :json

      private

        def respond_with(resource, _opts = {})
   token = request.env['warden-jwt_auth.token']
  puts "JWT token dispatched: #{token.inspect}"
  puts "🔍 Path: #{request.path}"
puts "🧪 Token: #{request.env['warden-jwt_auth.token'].inspect}"

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