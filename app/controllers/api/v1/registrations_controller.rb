module Api
  module V1
    class RegistrationsController < Devise::RegistrationsController
      respond_to :json

      def create
        build_resource(sign_up_params)

        if resource.save
          sign_in(resource)
          token = Warden::JWTAuth::UserEncoder.new.call(resource, :user, nil).first

          render json: {
            message: "Account created successfully",
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
          render json: { error: resource.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end
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
    end
  end
end