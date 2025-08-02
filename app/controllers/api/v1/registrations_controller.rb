# app/controllers/api/v1/registrations_controller.rb
module Api
  module V1
    class RegistrationsController < Devise::RegistrationsController
      respond_to :json
      skip_before_action :verify_authenticity_token
      skip_before_action :authenticate_user!

      def create
        build_resource(sign_up_params)

        if resource.save
          sign_in(resource) # <- Logs the user in
          token = request.env['warden-jwt_auth.token'] # Devise-JWT

          render json: {
            user: resource,
            token: token
          }, status: :created
        else
          render json: {
            error: resource.errors.full_messages.to_sentence
          }, status: :unprocessable_entity
        end
      end

      private

      def sign_up_params
        params.require(:user).permit(
          :email,
          :first_name,
          :last_name,
          :phone_number,
          :password,
          :password_confirmation
        )
      end
    end
  end
end