module Api
  module V1
    class RegistrationsController < Devise::RegistrationsController
      respond_to :json

      # Disable CSRF protection for API
      skip_before_action :verify_authenticity_token
      # Skip session storage (for API-only apps using JWT)
      skip_before_action :require_no_authentication

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

      def respond_with(resource, _opts = {})
        if resource.persisted?
          token = generate_jwt(resource)
          render json: {
            message: 'Signup successful',
            token: token,
            user: {
              id: resource.id,
              email: resource.email,
              first_name: resource.first_name,
              last_name: resource.last_name,
              phone_number: resource.phone_number,
              roles: resource.roles.pluck(:name)
            }
          }, status: :created
        else
          render json: { errors: resource.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def generate_jwt(user)
        Warden::JWTAuth::UserEncoder.new.call(user, :user, nil).first
      end
    end
  end
end