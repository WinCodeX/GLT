# app/controllers/api/v1/businesses_controller.rb
module Api
  module V1
    class BusinessesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_business, only: [:show, :update, :destroy]
      before_action :authorize_business_access, only: [:show]
      before_action :authorize_business_owner, only: [:update, :destroy]

      def create
  ActiveRecord::Base.transaction do
    business = Business.new(business_params.except(:category_ids).merge(owner: current_user))

    if business.save
      # Handle categories safely
      if params.dig(:business, :category_ids).present?
        category_ids = params[:business][:category_ids].first(5)
        valid_categories = Category.active.where(id: category_ids)
        business.categories = valid_categories
      end

      # Create owner relationship
      UserBusiness.create!(user: current_user, business: business, role: 'owner')

      render json: { 
        success: true, 
        message: "Business created successfully",
        business: business_json(business)
      }, status: :created
    else
      render json: { 
        success: false,
        message: "Failed to create business",
        errors: business.errors.full_messages 
      }, status: :unprocessable_entity
    end
  end
rescue ActiveRecord::RecordInvalid => e
  render json: { 
    success: false,
    message: "Validation failed",
    errors: [e.message]
  }, status: :unprocessable_entity
end

      def update
        ActiveRecord::Base.transaction do
          if @business.update(business_params.except(:category_ids))
            # Update categories if provided
            if params[:business][:category_ids].present?
              category_ids = params[:business][:category_ids].first(5) # Limit to 5
              valid_categories = Category.active.where(id: category_ids)
              @business.categories = valid_categories
            end

            render json: { 
              success: true, 
              message: "Business updated successfully",
              business: business_json(@business)
            }, status: :ok
          else
            render json: { 
              success: false,
              message: "Failed to update business",
              errors: @business.errors.full_messages 
            }, status: :unprocessable_entity
          end
        end
      rescue ActiveRecord::RecordInvalid => e
        render json: { 
          success: false,
          message: "Validation failed",
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      def index
        owned_businesses = current_user.user_businesses
                                      .includes(business: :categories)
                                      .where(role: 'owner')
                                      .map(&:business)

        joined_businesses = current_user.user_businesses
                                       .includes(business: :categories)
                                       .where(role: 'staff')
                                       .map(&:business)

        render json: {
          success: true,
          data: {
            owned: owned_businesses.map { |business| business_json(business) },
            joined: joined_businesses.map { |business| business_json(business) }
          },
          meta: {
            owned_count: owned_businesses.length,
            joined_count: joined_businesses.length,
            total_count: owned_businesses.length + joined_businesses.length
          }
        }, status: :ok
      end

      def show
        render json: {
          success: true,
          business: business_json(@business, include_owner: true, include_stats: true)
        }, status: :ok
      end

      def destroy
        if @business.destroy
          render json: {
            success: true,
            message: "Business deleted successfully"
          }, status: :ok
        else
          render json: {
            success: false,
            message: "Failed to delete business",
            errors: @business.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      private

      def set_business
        @business = Business.includes(:categories, :owner).find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: "Business not found" 
        }, status: :not_found
      end

      def authorize_business_access
        unless @business.owner == current_user || @business.users.include?(current_user)
          render json: { 
            success: false, 
            message: "Unauthorized access" 
          }, status: :forbidden
        end
      end

      def authorize_business_owner
        unless @business.owner == current_user
          render json: { 
            success: false, 
            message: "Only business owner can perform this action" 
          }, status: :forbidden
        end
      end

      def business_params
        params.require(:business).permit(:name, :phone_number, category_ids: [])
      end

      def business_json(business, include_owner: false, include_stats: false)
        json = {
          id: business.id,
          name: business.name,
          phone_number: business.phone_number,
          categories: business.categories.active.map do |category|
            {
              id: category.id,
              name: category.name,
              slug: category.slug,
              description: category.description
            }
          end,
          created_at: business.created_at,
          updated_at: business.updated_at
        }

        if include_owner
          json[:owner] = {
            id: business.owner.id,
            email: business.owner.email,
            name: business.owner.name
          }
        end

        if include_stats
          json[:stats] = {
            total_users: business.users.count,
            category_count: business.categories.count
          }
        end

        json
      end
    end
  end
end