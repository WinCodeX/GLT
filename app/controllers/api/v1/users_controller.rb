# app/controllers/api/v1/users_controller.rb
module Api
  module V1
    class UsersController < ApplicationController
      before_action :authenticate_user!
      before_action :ensure_admin, only: [:index, :assign_role]

      # GET /api/v1/users/me
      def me
        render json: current_user, serializer: UserSerializer
      end

      # GET /api/v1/users
      def index
        users = User.includes(:roles, :avatar_attachment, :avatar_blob)
        render json: users, each_serializer: UserSerializer
      end

      # PATCH /api/v1/users/:id/assign_role
      def assign_role
        user = User.find(params[:id])
        role = params[:role]

        if Role.exists?(name: role)
          user.add_role(role.to_sym)
          render json: { message: "#{role} role assigned to #{user.email}" }
        else
          render json: { error: "Invalid role: #{role}" }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/users/update
      def update
        if current_user.update(user_params)
          render json: current_user, serializer: UserSerializer
        else
          render json: { errors: current_user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def user_params
        params.require(:user).permit(:email, :password, :avatar)
      end

      def ensure_admin
        render json: { error: "Access denied" }, status: :forbidden unless current_user.has_role?(:admin)
      end
    end
  end
end