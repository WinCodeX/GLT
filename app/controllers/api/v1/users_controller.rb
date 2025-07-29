# app/controllers/api/v1/users_controller.rb
module Api
  module V1
    class UsersController < ApplicationController
      before_action :authenticate_user!
      before_action :ensure_admin, only: [:index, :assign_role]

      # GET /api/v1/me
      def me
        render json: {
          id: current_user.id,
          email: current_user.email,
          roles: current_user.roles.pluck(:name)
        }
      end

      # GET /api/v1/users
      def index
        users = User.includes(:roles).all
        render json: users.map { |u|
          {
            id: u.id,
            email: u.email,
            roles: u.roles.pluck(:name)
          }
        }
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

# app/controllers/api/v1/users_controller.rb
def update
  if current_user.update(user_params)
    render json: current_user, status: :ok
  else
    render json: { errors: current_user.errors.full_messages }, status: :unprocessable_entity
  end
end


      private

 def user_params
  params.require(:user).permit(:email, :password, :avatar)
 end


      def ensure_admin
        unless current_user.has_role?(:admin)
          render json: { error: "Access denied" }, status: :forbidden
        end
      end
    end
  end
end