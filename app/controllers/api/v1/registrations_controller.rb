# app/controllers/api/v1/registrations_controller.rb
module Api
  module V1
    class RegistrationsController < Devise::RegistrationsController
      respond_to :json
      
skip_before_action :verify_authenticity_token
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
          token = Warden::JWTAuth::UserEncoder.new.call(resource, :user, nil).first
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
    end
  end
end