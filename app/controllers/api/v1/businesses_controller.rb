module Api
  module V1
    class BusinessesController < ApplicationController
      before_action :authenticate_user!

      def create
  business = Business.new(business_params)
  business.owner = current_user

  if business.save
    UserBusiness.create!(user: current_user, business: business, role: 'owner')
    render json: { success: true, business: business }, status: :created
  else
    render json: { errors: business.errors.full_messages }, status: :unprocessable_entity
  end
end

      def index
  owned = current_user.user_businesses
                      .includes(:business)
                      .where(role: 'owner')
                      .map(&:business)

  joined = current_user.user_businesses
                       .includes(:business)
                       .where(role: 'staff')
                       .map(&:business)

  render json: {
    owned: owned.as_json(only: [:id, :name]),
    joined: joined.as_json(only: [:id, :name])
  }, status: :ok
end

      def show
        business = Business.find(params[:id])
        if business.owner == current_user || business.users.include?(current_user)
          render json: business, status: :ok
        else
          render json: { error: "Unauthorized" }, status: :forbidden
        end
      end

      private

      def business_params
        params.require(:business).permit(:name)
      end
    end
  end
end