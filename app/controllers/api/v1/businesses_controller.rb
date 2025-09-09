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
          Rails.logger.info "Creating business for user #{current_user.id} with params: #{business_params}"
          
          # Build business with owner but don't save yet
          @business = Business.new(business_params.except(:category_ids))
          @business.owner = current_user

          # Handle categories BEFORE validation
          if params.dig(:business, :category_ids).present?
            category_ids = Array(params[:business][:category_ids]).first(5)
            Rails.logger.info "Attaching categories: #{category_ids}"
            
            valid_categories = Category.active.where(id: category_ids)
            Rails.logger.info "Found valid categories: #{valid_categories.pluck(:id)}"
            
            if valid_categories.empty?
              return render json: { 
                success: false,
                message: "No valid categories found",
                errors: ["Please select at least one valid category"]
              }, status: :unprocessable_entity
            end
            
            # Attach categories to the business object (not persisted yet)
            @business.categories = valid_categories
          else
            return render json: { 
              success: false,
              message: "Categories are required",
              errors: ["Please select at least one category"]
            }, status: :unprocessable_entity
          end

          # Validate the business with categories attached
          unless @business.valid?
            Rails.logger.error "Business validation failed: #{@business.errors.full_messages}"
            return render json: { 
              success: false,
              message: "Validation failed",
              errors: @business.errors.full_messages 
            }, status: :unprocessable_entity
          end

          # Save the business (this will save the business and create category associations)
          if @business.save!
            Rails.logger.info "Business created successfully: #{@business.id}"
            
            # Note: UserBusiness relationship is not needed since we already have owner
            # The owner relationship is sufficient for business ownership
            
            render json: { 
              success: true, 
              message: "Business created successfully",
              data: { business: business_json(@business) }
            }, status: :created
          end

        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.error "Business creation validation error: #{e.message}"
          render json: { 
            success: false,
            message: "Validation failed",
            errors: [e.message]
          }, status: :unprocessable_entity
          
        rescue StandardError => e
          Rails.logger.error "Business creation error: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { 
            success: false,
            message: "Failed to create business",
            errors: ["An unexpected error occurred. Please try again."]
          }, status: :internal_server_error
        end
      end

      def update
        ActiveRecord::Base.transaction do
          Rails.logger.info "Updating business #{@business.id} with params: #{business_params}"
          
          if @business.update(business_params.except(:category_ids))
            # Update categories if provided
            if params.dig(:business, :category_ids).present?
              category_ids = Array(params[:business][:category_ids]).first(5)
              valid_categories = Category.active.where(id: category_ids)
              Rails.logger.info "Updating categories to: #{valid_categories.pluck(:id)}"
              @business.categories = valid_categories
            end

            render json: { 
              success: true, 
              message: "Business updated successfully",
              data: { business: business_json(@business) }
            }, status: :ok
          else
            Rails.logger.error "Business update validation failed: #{@business.errors.full_messages}"
            render json: { 
              success: false,
              message: "Failed to update business",
              errors: @business.errors.full_messages 
            }, status: :unprocessable_entity
          end
        end
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "Business update validation error: #{e.message}"
        render json: { 
          success: false,
          message: "Validation failed",
          errors: [e.message]
        }, status: :unprocessable_entity
      rescue StandardError => e
        Rails.logger.error "Business update error: #{e.class} - #{e.message}"
        render json: { 
          success: false,
          message: "Failed to update business",
          errors: ["An unexpected error occurred. Please try again."]
        }, status: :internal_server_error
      end

      def index
        begin
          # Get businesses where user is owner through the owner relationship
          owned_businesses = Business.includes(:categories, :owner)
                                   .where(owner: current_user)
                                   .order(created_at: :desc)

          # Get businesses where user is staff through UserBusiness relationship
          joined_businesses = current_user.user_businesses
                                         .includes(business: [:categories, :owner])
                                         .where(role: 'staff')
                                         .map(&:business)

          Rails.logger.info "User #{current_user.id} has #{owned_businesses.count} owned and #{joined_businesses.count} joined businesses"

          render json: {
            success: true,
            data: {
              owned: owned_businesses.map { |business| business_json(business) },
              joined: joined_businesses.map { |business| business_json(business) }
            },
            meta: {
              owned_count: owned_businesses.count,
              joined_count: joined_businesses.count,
              total_count: owned_businesses.count + joined_businesses.count
            }
          }, status: :ok
          
        rescue StandardError => e
          Rails.logger.error "Error fetching businesses: #{e.class} - #{e.message}"
          render json: {
            success: false,
            message: "Failed to fetch businesses",
            errors: ["Unable to load businesses. Please try again."]
          }, status: :internal_server_error
        end
      end

      def show
        render json: {
          success: true,
          data: { business: business_json(@business, include_owner: true, include_stats: true) }
        }, status: :ok
      end

      def destroy
        begin
          if @business.destroy
            Rails.logger.info "Business #{@business.id} deleted successfully"
            render json: {
              success: true,
              message: "Business deleted successfully"
            }, status: :ok
          else
            Rails.logger.error "Failed to delete business #{@business.id}: #{@business.errors.full_messages}"
            render json: {
              success: false,
              message: "Failed to delete business",
              errors: @business.errors.full_messages
            }, status: :unprocessable_entity
          end
        rescue StandardError => e
          Rails.logger.error "Error deleting business: #{e.class} - #{e.message}"
          render json: {
            success: false,
            message: "Failed to delete business",
            errors: ["An unexpected error occurred. Please try again."]
          }, status: :internal_server_error
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
        permitted_params = params.require(:business).permit(:name, :phone_number, category_ids: [])
        Rails.logger.info "Permitted params: #{permitted_params}"
        permitted_params
      end

      def business_json(business, include_owner: false, include_stats: false)
        json = {
          id: business.id,
          name: business.name,
          phone_number: business.phone_number,
          logo_url: business.logo_url,
          categories: business.categories.active.map do |category|
            {
              id: category.id,
              name: category.name,
              slug: category.slug,
              description: category.description
            }
          end,
          created_at: business.created_at.iso8601,
          updated_at: business.updated_at.iso8601
        }

        if include_owner && business.owner
          json[:owner] = {
            id: business.owner.id,
            email: business.owner.email,
            name: business.owner.name
          }
        end

        if include_stats
          json[:stats] = {
            total_users: business.users.count + 1, # +1 for owner
            category_count: business.categories.count
          }
        end

        json
      end
    end
  end
end