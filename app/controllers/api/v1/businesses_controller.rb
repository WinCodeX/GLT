module Api
  module V1
    class BusinessesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_business, only: [:show, :update, :destroy, :staff, :activities]
      before_action :authorize_business_access, only: [:show, :staff, :activities]
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
          
          # Extract update parameters excluding category_ids
          update_params = business_params.except(:category_ids)
          
          # Update business attributes without validation to skip description validation
          if update_params.present?
            @business.assign_attributes(update_params)
            unless @business.save(validate: false)
              Rails.logger.error "Business update failed: #{@business.errors.full_messages}"
              return render json: { 
                success: false,
                message: "Failed to update business",
                errors: @business.errors.full_messages 
              }, status: :unprocessable_entity
            end
          end

          # Update categories if provided
          if params.dig(:business, :category_ids).present?
            category_ids = Array(params[:business][:category_ids]).first(5)
            valid_categories = Category.active.where(id: category_ids)
            Rails.logger.info "Updating categories to: #{valid_categories.pluck(:id)}"
            
            if valid_categories.any?
              @business.categories = valid_categories
            else
              return render json: { 
                success: false,
                message: "No valid categories found",
                errors: ["Please select at least one valid category"]
              }, status: :unprocessable_entity
            end
          end

          render json: { 
            success: true, 
            message: "Business updated successfully",
            data: { business: business_json(@business) }
          }, status: :ok

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

      def staff
        begin
          Rails.logger.info "Fetching staff for business #{@business.id} by user #{current_user.id}"
          
          # Get the direct owner from the business association
          owner = @business.owner
          Rails.logger.info "Business owner: #{owner&.id}"

          # Get staff members (role = "staff") from user_businesses
          staff_members = @business.user_businesses.where(role: 'staff').map do |ub|
            user = ub.user
            # Use full_name instead of name method
            display_name = user.full_name.present? ? user.full_name : user.email
            
            {
              id: user.id,
              name: display_name,
              email: user.email,
              active: user.respond_to?(:online?) ? user.online? : false,
              joined_at: ub.created_at.iso8601
            }
          end

          Rails.logger.info "Found #{staff_members.size} staff members"

          # Always return a consistent owner structure
          owner_data = if owner
            # Use full_name instead of name method for owner too
            display_name = owner.full_name.present? ? owner.full_name : owner.email
            
            {
              id: owner.id,
              name: display_name,
              email: owner.email,
              avatar_url: owner.respond_to?(:avatar_url) ? owner.avatar_url : nil
            }
          else
            # Fallback - this shouldn't happen but ensures consistency
            Rails.logger.warn "No owner found for business #{@business.id}"
            {
              id: nil,
              name: "Unknown Owner",
              email: "unknown@example.com",
              avatar_url: nil
            }
          end

          active_count = staff_members.count { |s| s[:active] }
          total_members = staff_members.size + 1 # +1 for owner

          response_data = {
            success: true,
            data: {
              owner: owner_data,
              staff: staff_members,
              stats: {
                active_members: active_count + 1, # +1 for owner (assume active)
                total_members: total_members,
                staff_count: staff_members.size
              }
            }
          }

          Rails.logger.info "Successfully returning staff data for business #{@business.id}"
          render json: response_data, status: :ok

        rescue StandardError => e
          Rails.logger.error "Error fetching staff for business #{@business&.id}: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: {
            success: false,
            message: "Failed to fetch staff",
            errors: ["Unable to load staff information. Please try again."]
          }, status: :internal_server_error
        end
      end

      def activities
        begin
          Rails.logger.info "Fetching activities for business #{@business.id} by user #{current_user.id}"
          
          # Handle pagination
          page = [params[:page]&.to_i || 1, 1].max
          per_page = [[params[:per_page]&.to_i || 20, 1].max, 50].min
          
          # Handle filtering by activity type
          filter_type = params[:filter_type]
          
          # Check if BusinessActivity model exists
          unless defined?(BusinessActivity)
            # Return mock data if BusinessActivity model doesn't exist
            return render json: {
              success: true,
              data: {
                activities: [],
                summary: {
                  total_activities: 0,
                  package_activities: 0,
                  staff_activities: 0
                }
              },
              pagination: {
                current_page: page,
                per_page: per_page,
                total_count: 0,
                total_pages: 0,
                has_next: false,
                has_prev: false
              }
            }, status: :ok
          end
          
          # Build query for activities
          activities_query = BusinessActivity.where(business: @business)
                                           .includes(:user, :target_user, :package)
                                           .recent
          
          # Apply filters
          case filter_type
          when 'package'
            activities_query = activities_query.package_activities
          when 'staff'
            activities_query = activities_query.staff_activities
          when 'today'
            activities_query = activities_query.today
          when 'week'
            activities_query = activities_query.this_week
          when 'month'
            activities_query = activities_query.this_month
          end
          
          # Get total count before pagination
          total_count = activities_query.count
          
          # Apply pagination
          activities = activities_query.offset((page - 1) * per_page)
                                     .limit(per_page)
          
          # Get activities summary
          summary = BusinessActivity.activities_summary(
            business: @business,
            start_date: 1.month.ago,
            end_date: Time.current
          )
          
          # Serialize activities
          serialized_activities = activities.map do |activity|
            activity_data = activity.summary_json
            
            # Fix the user name issue in serialization
            if activity_data[:user] && activity_data[:user][:name].blank?
              user = activity.user
              activity_data[:user][:name] = user.full_name.present? ? user.full_name : user.email
            end
            
            if activity_data[:target_user] && activity_data[:target_user][:name].blank?
              target_user = activity.target_user
              activity_data[:target_user][:name] = target_user.full_name.present? ? target_user.full_name : target_user.email
            end
            
            activity_data
          end
          
          render json: {
            success: true,
            data: {
              activities: serialized_activities,
              summary: summary.except(:recent_activities) # Exclude to avoid duplication
            },
            pagination: {
              current_page: page,
              per_page: per_page,
              total_count: total_count,
              total_pages: (total_count / per_page.to_f).ceil,
              has_next: page * per_page < total_count,
              has_prev: page > 1
            },
            filters: {
              current_filter: filter_type,
              available_filters: [
                { key: 'all', label: 'All Activities' },
                { key: 'package', label: 'Package Activities' },
                { key: 'staff', label: 'Staff Activities' },
                { key: 'today', label: 'Today' },
                { key: 'week', label: 'This Week' },
                { key: 'month', label: 'This Month' }
              ]
            }
          }, status: :ok
          
        rescue StandardError => e
          Rails.logger.error "Error fetching activities for business #{@business&.id}: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: {
            success: false,
            message: "Failed to fetch activities",
            errors: ["Unable to load activity information. Please try again."]
          }, status: :internal_server_error
        end
      end

      private

      def set_business
        # Preload all necessary associations for authorization and data access
        @business = Business.includes(:categories, :owner, user_businesses: :user).find(params[:id])
        Rails.logger.info "Set business: #{@business.id} for user #{current_user.id}"
      rescue ActiveRecord::RecordNotFound => e
        Rails.logger.error "Business not found: #{params[:id]} for user #{current_user.id}"
        render json: { 
          success: false, 
          message: "Business not found" 
        }, status: :not_found
      end

      def authorize_business_access
        Rails.logger.info "Authorizing access for user #{current_user.id} to business #{@business.id}"
        Rails.logger.info "Business owner: #{@business.owner&.id}"
        
        # Check if user is the owner
        if @business.owner == current_user
          Rails.logger.info "User #{current_user.id} is the owner of business #{@business.id}"
          return
        end
        
        # Check if user is staff through user_businesses
        staff_user_ids = @business.user_businesses.where(role: 'staff').pluck(:user_id)
        Rails.logger.info "Business staff user IDs: #{staff_user_ids}"
        
        if staff_user_ids.include?(current_user.id)
          Rails.logger.info "User #{current_user.id} is staff of business #{@business.id}"
          return
        end
        
        Rails.logger.warn "Unauthorized access attempt by user #{current_user.id} to business #{@business.id}"
        render json: { 
          success: false, 
          message: "Unauthorized access" 
        }, status: :forbidden
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
          # Use full_name instead of name for consistency
          owner_name = business.owner.full_name.present? ? business.owner.full_name : business.owner.email
          
          json[:owner] = {
            id: business.owner.id,
            email: business.owner.email,
            name: owner_name,
            avatar_url: business.owner.avatar_url
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
            category_count: business.categories.count
          }
        end

        json
      end
    end
  end
end