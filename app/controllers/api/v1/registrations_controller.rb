# app/controllers/api/v1/registrations_controller.rb
module Api
  module V1
    class RegistrationsController < ApplicationController
      def create
        user = User.new(user_params)
        if user.save
          render json: { message: "Signup successful", user: user }, status: :created
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