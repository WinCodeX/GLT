module Api
  module V1
    class RegistrationsController < ApplicationController
      def create
        user = User.new(user_params)
        if user.save
          # Add default role if no roles exist
          user.add_role(:client) if user.roles.blank?

          # Generate JWT token (no session writing involved)
          jwt = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil).first

          render json: { 
            message: "Signup successful", 
            token: jwt,
            user: {
              id: user.id,
              email: user.email,
              first_name: user.first_name,
              last_name: user.last_name,
              phone_number: user.phone_number,
              roles: user.roles.pluck(:name)
            }
          }, status: :created
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def user_params
        params.require(:user).permit(:email, :password, :password_confirmation, :first_name, :last_name, :phone_number)
      end
    end
  end
end