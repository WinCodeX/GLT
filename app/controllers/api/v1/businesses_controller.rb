# app/controllers/api/v1/businesses_controller.rb
module Api
  module V1
    class BusinessesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_business, only: [:show, :update, :destroy, :staff, :activities, :logo]
      before_action :authorize_business_access, only: [:show, :staff, :activities]
      before_action :authorize_business_owner, only: [:update, :destroy, :logo]

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
            
            # Create initial business activity
            BusinessActivity.create_business_activity(
              business: @business,
              user: current_user,
              activity_type: 'business_created',
              metadata: { categories: valid_categories.pluck(:name) }
            )
            
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
          
          old_name = @business.name
          old_categories = @business.categories.pluck(:name)
          
          if @business.update(business_params.except(:category_ids))
            # Update categories if provided
            if params.dig(:business, :category_ids).present?
              category_ids = Array(params[:business][:category_ids]).first(5)
              valid_categories = Category.active.where(id: category_ids)
              Rails.logger.info "Updating categories to: #{valid_categories.pluck(:id)}"
              @business.categories = valid_categories
              
              # Create activity if categories changed
              new_categories = valid_categories.pluck(:name)
              if old_categories.sort != new_categories.sort
                BusinessActivity.create_business_activity(
                  business: @business,
                  user: current_user,
                  activity_type: 'categories_updated',
                  metadata: { 
                    old_categories: old_categories,
                    new_categories: new_categories
                  }
                )
              end
            end

            # Create activity if business name changed
            if old_name != @business.name
              BusinessActivity.create_business_activity(
                business: @business,
                user: current_user,
                activity_type: 'business_updated',
                metadata: { 
                  old_name: old_name,
                  new_name: @business.name
                }
              )
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
              owned: owned_businesses.map { |business| business_json(business, include_stats: true) },
              joined: joined_businesses.map { |business| business_json(business, include_stats: true) }
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

      # GET /api/v1/businesses/:id/staff
      def staff
        begin
          Rails.logger.info "Fetching staff for business #{@business.id}"
          
          # Get all staff members (excluding owner)
          staff_members = @business.user_businesses
                                  .includes(:user)
                                  .where(role: 'staff')
                                  .order(created_at: :desc)

          # Get owner information
          owner_info = {
            id: @business.owner.id,
            name: @business.owner.name,
            email: @business.owner.email,
            avatar_url: @business.owner.avatar_url,
            role: 'owner',
            joined_at: @business.created_at.iso8601,
            active: true
          }

          # Format staff data
          staff_data = staff_members.map do |user_business|
            user = user_business.user
            {
              id: user.id,
              name: user.name,
              email: user.email,
              avatar_url: user.avatar_url,
              role: user_business.role,
              joined_at: user_business.created_at.iso8601,
              active: user.last_seen_at && user.last_seen_at > 30.days.ago
            }
          end

          Rails.logger.info "Found #{staff_data.count} staff members for business #{@business.id}"

          render json: {
            success: true,
            data: {
              owner: owner_info,
              staff: staff_data,
              total_members: staff_data.count + 1, # +1 for owner
              active_members: staff_data.count { |s| s[:active] } + 1 # +1 for owner
            }
          }, status: :ok

        rescue StandardError => e
          Rails.logger.error "Error fetching business staff: #{e.class} - #{e.message}"
          render json: {
            success: false,
            message: "Failed to fetch staff members",
            errors: ["Unable to load staff. Please try again."]
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/businesses/:id/activities
      def activities
        begin
          Rails.logger.info "Fetching activities for business #{@business.id}"
          
          # Get activities with pagination
          page = (params[:page] || 1).to_i
          per_page = (params[:per_page] || 20).to_i
          
          activities = @business.business_activities
                               .includes(:user, :target_user, :package)
                               .recent
                               .page(page)
                               .per(per_page)

          # Get summary statistics
          summary = BusinessActivity.activities_summary(
            business: @business,
            start_date: 30.days.ago,
            end_date: Time.current
          )

          Rails.logger.info "Found #{activities.count} activities for business #{@business.id}"

          render json: {
            success: true,
            data: {
              activities: activities.map(&:summary_json),
              summary: summary,
              pagination: {
                current_page: page,
                per_page: per_page,
                total_pages: activities.total_pages,
                total_count: activities.total_count
              }
            }
          }, status: :ok

        rescue StandardError => e
          Rails.logger.error "Error fetching business activities: #{e.class} - #{e.message}"
          render json: {
            success: false,
            message: "Failed to fetch activities",
            errors: ["Unable to load activities. Please try again."]
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/businesses/:id/logo
      def logo
        begin
          Rails.logger.info "Uploading logo for business #{@business.id}"
          
          uploaded_file = params[:logo]
          unless uploaded_file
            return render json: {
              success: false,
              message: "No logo file provided",
              errors: ["Please select a logo file"]
            }, status: :unprocessable_entity
          end

          # Process logo upload (this would integrate with your existing upload system)
          logo_url = process_business_logo_upload(uploaded_file, @business)
          
          if logo_url
            # Create activity for logo update
            BusinessActivity.create_business_activity(
              business: @business,
              user: current_user,
              activity_type: 'logo_updated',
              metadata: { logo_url: logo_url }
            )
            
            render json: {
              success: true,
              message: "Business logo updated successfully",
              data: { logo_url: logo_url }
            }, status: :ok
          else
            render json: {
              success: false,
              message: "Failed to upload logo",
              errors: ["Logo upload failed. Please try again."]
            }, status: :unprocessable_entity
          end

        rescue StandardError => e
          Rails.logger.error "Error uploading business logo: #{e.class} - #{e.message}"
          render json: {
            success: false,
            message: "Failed to upload logo",
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
          total_staff = business.user_businesses.where(role: 'staff').count
          active_staff = business.user_businesses
                               .joins(:user)
                               .where(role: 'staff')
                               .where('users.last_seen_at > ?', 30.days.ago)
                               .count

          json[:stats] = {
            total_members: total_staff + 1, # +1 for owner
            active_members: active_staff + 1, # +1 for owner (assume active)
            staff_count: total_staff,
            category_count: business.categories.count,
            recent_activity: business.business_activities.recent.first&.created_at&.iso8601
          }
        end

        json
      end

      def process_business_logo_upload(uploaded_file, business)
        # This method would integrate with your existing file upload system
        # For now, return a placeholder - you'd implement the actual upload logic
        # similar to how avatar uploads work in your existing system
        
        # Example integration with existing upload system:
        # BusinessLogoUploadService.new(business, uploaded_file).call
        
        Rails.logger.info "Processing logo upload for business #{business.id}"
        "/uploads/business_logos/#{business.id}/logo.jpg" # Placeholder
      end
    end
  end
end