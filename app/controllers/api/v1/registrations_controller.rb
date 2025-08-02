module Api
  module V1
    class RegistrationsController < Devise::RegistrationsController
      respond_to :json
      skip_before_action :verify_authenticity_token, if: :json_request?

      def create
        build_resource(sign_up_params)

        if resource.save
          # Generate JWT token using devise-jwt
          token = request.env['warden-jwt_auth.token']
          
          # If token is not available from warden, generate manually
          token ||= JWT.encode(
            { 
              sub: resource.id,
              exp: 24.hours.from_now.to_i,
              iat: Time.current.to_i
            },
            Rails.application.credentials.devise_jwt_secret_key || Rails.application.secret_key_base
          )

          render json: {
            message: "Account created successfully",
            token: token,
            user: user_json(resource)
          }, status: :created
        else
          render json: { 
            error: "Registration failed",
            errors: resource.errors.full_messages 
          }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error "Registration error: #{e.message}"
        render json: { 
          error: "Registration failed. Please try again." 
        }, status: :internal_server_error
      end

      private

      def sign_up_params
        params.require(:user).permit(
          :email,
          :password,
          :password_confirmation,
          :first_name,
          :last_name,
          :phone_number
        )
      end

      def user_json(user)
        {
          id: user.id,
          email: user.email,
          first_name: user.first_name,
          last_name: user.last_name,
          phone_number: user.phone_number,
          roles: user.roles&.pluck(:name) || []
        }
      end

      def json_request?
        request.format.json?
      end
    end
  end
end