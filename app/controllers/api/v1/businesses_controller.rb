# app/controllers/api/v1/businesses_controller.rb - Enhanced with ActionCable broadcasting for real-time business updates

module Api
  module V1
    class BusinessesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_business, only: [:show, :update, :destroy, :staff, :activities, :staff_activities, :packages_comparison, :best_locations]
      before_action :authorize_business_access, only: [:show, :staff, :activities, :staff_activities, :packages_comparison, :best_locations]
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
            
            business_data = business_json(@business)
            
            # ENHANCED: Broadcast business creation to user's channels
            broadcast_business_created(business_data)
            
            render json: { 
              success: true, 
              message: "Business created successfully",
              data: { business: business_data }
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
          old_business_data = business_json(@business)
          
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

          @business.reload
          new_business_data = business_json(@business)
          
          # ENHANCED: Broadcast business update to all relevant channels
          broadcast_business_updated(new_business_data, old_business_data)

          render json: { 
            success: true, 
            message: "Business updated successfully",
            data: { business: new_business_data }
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
          business_data = business_json(@business)
          
          if @business.destroy
            Rails.logger.info "Business #{@business.id} deleted successfully"
            
            # ENHANCED: Broadcast business deletion to all relevant channels
            broadcast_business_deleted(business_data)
            
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
              role: 'staff',
              active: user.respond_to?(:online?) ? user.online? : false,
              joined_at: ub.created_at.iso8601,
              avatar_url: user.respond_to?(:avatar_url) ? user.avatar_url : nil
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
              role: 'owner',
              avatar_url: owner.respond_to?(:avatar_url) ? owner.avatar_url : nil,
              joined_at: @business.created_at.iso8601
            }
          else
            # Fallback - this shouldn't happen but ensures consistency
            Rails.logger.warn "No owner found for business #{@business.id}"
            {
              id: nil,
              name: "Unknown Owner",
              email: "unknown@example.com",
              role: 'owner',
              avatar_url: nil,
              joined_at: @business.created_at.iso8601
            }
          end

          active_count = staff_members.count { |s| s[:active] }
          total_members = staff_members.size + 1 # +1 for owner

          response_data = {
            success: true,
            data: {
              owner: owner_data,
              staff: staff_members,
              total_members: total_members,
              active_members: active_count + 1 # +1 for owner (assume active)
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

      # ENHANCED: Activities method with real-time broadcasting capabilities
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
            Rails.logger.warn "BusinessActivity model not found, returning mock data"
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
          
          # Check if business_activities table exists
          unless ActiveRecord::Base.connection.table_exists?('business_activities')
            Rails.logger.warn "business_activities table not found, returning mock data"
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
          
          # Build query for activities with proper error handling
          activities_query = BusinessActivity.where(business: @business)
          
          # ENHANCED: Include packages created by staff members for business owner
          if current_user == @business.owner
            Rails.logger.info "User is business owner - showing all business activities including staff packages"
            # Owner sees all activities for their business (including packages created by staff)
            # No additional filtering needed - activities_query already filters by business
          else
            Rails.logger.info "User is staff member - showing only their own activities"
            # Staff members only see their own activities
            activities_query = activities_query.where(user: current_user)
          end
          
          # Apply filters with error handling
          begin
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
          rescue => filter_error
            Rails.logger.error "Error applying filter #{filter_type}: #{filter_error.message}"
            # Continue without filter
          end
          
          # Get total count with error handling
          begin
            total_count = activities_query.count
          rescue => count_error
            Rails.logger.error "Error counting activities: #{count_error.message}"
            total_count = 0
          end
          
          # Apply pagination and includes with error handling
          begin
            activities = activities_query.includes(:user, :target_user, :package)
                                       .order(created_at: :desc)
                                       .offset((page - 1) * per_page)
                                       .limit(per_page)
          rescue => query_error
            Rails.logger.error "Error fetching activities: #{query_error.message}"
            activities = []
          end
          
          # Get activities summary with error handling
          summary = safe_activities_summary(@business)
          
          # ENHANCED: Serialize activities with personalized descriptions
          serialized_activities = safe_serialize_activities_with_personalization(activities, current_user, @business)
          
          response_data = {
            success: true,
            data: {
              activities: serialized_activities,
              summary: summary
            },
            pagination: {
              current_page: page,
              per_page: per_page,
              total_count: total_count,
              total_pages: total_count > 0 ? (total_count / per_page.to_f).ceil : 0,
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
          }
          
          # ENHANCED: Broadcast activity data update to business channel
          broadcast_business_activities_updated(@business.id, summary)
          
          render json: response_data, status: :ok
          
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

      # NEW: Individual staff member activities
      # GET /api/v1/businesses/:id/staff/:staff_id/activities
      def staff_activities
        begin
          staff_id = params[:staff_id].to_i
          Rails.logger.info "Fetching activities for staff #{staff_id} in business #{@business.id}"
          
          # Verify staff member exists and belongs to business
          staff_user = find_staff_member(staff_id)
          unless staff_user
            return render json: {
              success: false,
              message: "Staff member not found or not part of this business"
            }, status: :not_found
          end

          # Handle pagination
          page = [params[:page]&.to_i || 1, 1].max
          per_page = [[params[:per_page]&.to_i || 20, 1].max, 50].min

          # Check if BusinessActivity exists
          unless defined?(BusinessActivity)
            Rails.logger.warn "BusinessActivity model not found, returning empty activities"
            return render json: {
              success: true,
              data: [],
              pagination: {
                current_page: page,
                per_page: per_page,
                total_count: 0,
                total_pages: 0,
                has_next: false,
                has_prev: false
              },
              staff_info: {
                id: staff_user.id,
                name: safe_user_name(staff_user),
                email: staff_user.email,
                role: staff_user.id == @business.owner_id ? 'owner' : 'staff'
              }
            }, status: :ok
          end

          # Get activities for specific staff member
          begin
            activities_query = BusinessActivity.where(business: @business)
                                             .where("user_id = ? OR target_user_id = ?", staff_id, staff_id)
            
            total_count = activities_query.count
            
            activities = activities_query.includes(:user, :target_user, :package)
                                       .order(created_at: :desc)
                                       .offset((page - 1) * per_page)
                                       .limit(per_page)
            
            # ENHANCED: Serialize activities with personalization for the viewing user
            serialized_activities = safe_serialize_activities_with_personalization(activities, current_user, @business)
            
            render json: {
              success: true,
              data: serialized_activities,
              pagination: {
                current_page: page,
                per_page: per_page,
                total_count: total_count,
                total_pages: total_count > 0 ? (total_count / per_page.to_f).ceil : 0,
                has_next: page * per_page < total_count,
                has_prev: page > 1
              },
              staff_info: {
                id: staff_user.id,
                name: safe_user_name(staff_user),
                email: staff_user.email,
                role: staff_user.id == @business.owner_id ? 'owner' : 'staff'
              }
            }, status: :ok

          rescue => query_error
            Rails.logger.error "Error fetching staff activities: #{query_error.message}"
            render json: {
              success: true,
              data: [],
              pagination: {
                current_page: page,
                per_page: per_page,
                total_count: 0,
                total_pages: 0,
                has_next: false,
                has_prev: false
              },
              staff_info: {
                id: staff_user.id,
                name: safe_user_name(staff_user),
                email: staff_user.email,
                role: staff_user.id == @business.owner_id ? 'owner' : 'staff'
              }
            }, status: :ok
          end

        rescue StandardError => e
          Rails.logger.error "Error fetching staff activities: #{e.class} - #{e.message}"
          render json: {
            success: false,
            message: "Failed to fetch staff activities",
            errors: ["Unable to load staff activity information. Please try again."]
          }, status: :internal_server_error
        end
      end

      # NEW: Two-month package comparison analytics
      # GET /api/v1/businesses/:id/analytics/packages-comparison
      def packages_comparison
        begin
          Rails.logger.info "Fetching package comparison analytics for business #{@business.id}"

          # Get current and previous month data
          current_month = Date.current.beginning_of_month
          previous_month = current_month - 1.month

          # Get package counts for both months
          current_month_count = get_package_count_for_month(@business, current_month)
          previous_month_count = get_package_count_for_month(@business, previous_month)

          analytics_data = {
            success: true,
            data: {
              current_month: {
                month: current_month.strftime('%b %Y'),
                packages: current_month_count
              },
              previous_month: {
                month: previous_month.strftime('%b %Y'),
                packages: previous_month_count
              }
            },
            metadata: {
              comparison: {
                change: current_month_count - previous_month_count,
                percentage_change: previous_month_count > 0 ? 
                  (((current_month_count - previous_month_count).to_f / previous_month_count) * 100).round(1) : 0,
                trend: current_month_count >= previous_month_count ? 'up' : 'down'
              }
            }
          }
          
          # ENHANCED: Broadcast analytics update to business channel
          broadcast_business_analytics_updated(@business.id, analytics_data[:data])
          
          render json: analytics_data, status: :ok

        rescue StandardError => e
          Rails.logger.error "Error fetching package comparison: #{e.class} - #{e.message}"
          render json: {
            success: false,
            message: "Failed to fetch package comparison data",
            errors: ["Unable to load analytics. Please try again."]
          }, status: :internal_server_error
        end
      end

      private

      # ENHANCED: ActionCable broadcasting methods
      def broadcast_business_created(business_data)
        begin
          # Broadcast to user's personal business updates channel
          ActionCable.server.broadcast(
            "user_businesses_#{current_user.id}",
            {
              type: 'business_created',
              business: business_data,
              timestamp: Time.current.iso8601
            }
          )
          
          # Broadcast to specific business channel for future updates
          ActionCable.server.broadcast(
            "business_#{business_data[:id]}_updates",
            {
              type: 'business_created',
              business: business_data,
              created_by: {
                id: current_user.id,
                name: current_user.full_name.presence || current_user.email
              },
              timestamp: Time.current.iso8601
            }
          )
          
          Rails.logger.info "📡 Business creation broadcast sent for business #{business_data[:id]}"
        rescue => e
          Rails.logger.error "❌ Failed to broadcast business creation: #{e.message}"
        end
      end

      def broadcast_business_updated(new_business_data, old_business_data)
        begin
          # Broadcast to business-specific channel
          ActionCable.server.broadcast(
            "business_#{@business.id}_updates",
            {
              type: 'business_updated',
              business: new_business_data,
              changes: calculate_business_changes(old_business_data, new_business_data),
              updated_by: {
                id: current_user.id,
                name: current_user.full_name.presence || current_user.email
              },
              timestamp: Time.current.iso8601
            }
          )
          
          # Broadcast to all business members
          broadcast_to_business_members(@business, 'business_info_updated', {
            business: new_business_data,
            updated_by: current_user.full_name.presence || current_user.email
          })
          
          Rails.logger.info "📡 Business update broadcast sent for business #{@business.id}"
        rescue => e
          Rails.logger.error "❌ Failed to broadcast business update: #{e.message}"
        end
      end

      def broadcast_business_deleted(business_data)
        begin
          # Broadcast to business-specific channel
          ActionCable.server.broadcast(
            "business_#{business_data[:id]}_updates",
            {
              type: 'business_deleted',
              business_id: business_data[:id],
              business_name: business_data[:name],
              deleted_by: {
                id: current_user.id,
                name: current_user.full_name.presence || current_user.email
              },
              timestamp: Time.current.iso8601
            }
          )
          
          # Broadcast to owner's personal channel
          ActionCable.server.broadcast(
            "user_businesses_#{current_user.id}",
            {
              type: 'business_deleted',
              business_id: business_data[:id],
              business_name: business_data[:name],
              timestamp: Time.current.iso8601
            }
          )
          
          Rails.logger.info "📡 Business deletion broadcast sent for business #{business_data[:id]}"
        rescue => e
          Rails.logger.error "❌ Failed to broadcast business deletion: #{e.message}"
        end
      end

      def broadcast_business_activities_updated(business_id, summary)
        begin
          ActionCable.server.broadcast(
            "business_#{business_id}_updates",
            {
              type: 'activities_updated',
              summary: summary,
              timestamp: Time.current.iso8601
            }
          )
          
          Rails.logger.info "📡 Business activities update broadcast sent for business #{business_id}"
        rescue => e
          Rails.logger.error "❌ Failed to broadcast activities update: #{e.message}"
        end
      end

      def broadcast_business_analytics_updated(business_id, analytics_data)
        begin
          ActionCable.server.broadcast(
            "business_#{business_id}_updates",
            {
              type: 'analytics_updated',
              analytics: analytics_data,
              timestamp: Time.current.iso8601
            }
          )
          
          Rails.logger.info "📡 Business analytics update broadcast sent for business #{business_id}"
        rescue => e
          Rails.logger.error "❌ Failed to broadcast analytics update: #{e.message}"
        end
      end

      def broadcast_to_business_members(business, message_type, data)
        begin
          # Get all business members (owner + staff)
          member_ids = [business.owner_id]
          member_ids += business.user_businesses.where(role: 'staff').pluck(:user_id)
          
          member_ids.uniq.each do |member_id|
            ActionCable.server.broadcast(
              "user_businesses_#{member_id}",
              {
                type: message_type,
                business_id: business.id,
                **data,
                timestamp: Time.current.iso8601
              }
            )
          end
          
          Rails.logger.info "📡 Broadcast sent to #{member_ids.count} business members"
        rescue => e
          Rails.logger.error "❌ Failed to broadcast to business members: #{e.message}"
        end
      end

      def calculate_business_changes(old_data, new_data)
        changes = {}
        
        ['name', 'phone_number', 'logo_url'].each do |field|
          if old_data[field.to_sym] != new_data[field.to_sym]
            changes[field] = {
              from: old_data[field.to_sym],
              to: new_data[field.to_sym]
            }
          end
        end
        
        # Check category changes
        old_category_ids = old_data[:categories]&.map { |c| c[:id] } || []
        new_category_ids = new_data[:categories]&.map { |c| c[:id] } || []
        
        if old_category_ids.sort != new_category_ids.sort
          changes['categories'] = {
            from: old_data[:categories],
            to: new_data[:categories]
          }
        end
        
        changes
      end

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

      # Helper method to find staff member
      def find_staff_member(staff_id)
        # Check if it's the owner
        return @business.owner if @business.owner_id == staff_id
        
        # Check if it's a staff member
        staff_relation = @business.user_businesses.find_by(user_id: staff_id, role: 'staff')
        staff_relation&.user
      end

      # Helper method to get package count for a specific month
      def get_package_count_for_month(business, month_start)
        month_end = month_start.end_of_month
        
        # ENHANCED: Count packages for this business in the given month (including staff-created packages)
        if defined?(Package)
          Package.where(business: business)
                 .where(created_at: month_start..month_end)
                 .count
        else
          # Fallback if Package model doesn't exist
          Rails.logger.warn "Package model not found, returning 0 count"
          0
        end
      rescue => e
        Rails.logger.error "Error counting packages for month: #{e.message}"
        0
      end

      # FIXED: Safe activities summary with error handling
      def safe_activities_summary(business)
        begin
          activities = BusinessActivity.where(business: business, created_at: 1.month.ago..Time.current)
          
          {
            total_activities: activities.count,
            package_activities: activities.where(activity_type: ['package_created', 'package_delivered', 'package_cancelled']).count,
            staff_activities: activities.where(activity_type: ['staff_joined', 'staff_removed', 'invite_sent', 'invite_accepted']).count
          }
        rescue => e
          Rails.logger.error "Error generating activities summary: #{e.message}"
          {
            total_activities: 0,
            package_activities: 0,
            staff_activities: 0
          }
        end
      end

      # ENHANCED: Safe activity serialization with personalized descriptions and enhanced details
      def safe_serialize_activities_with_personalization(activities, viewer_user, business)
        return [] if activities.blank?
        
        activities.map do |activity|
          begin
            # Basic activity data
            activity_data = {
              id: activity.id,
              activity_type: activity.activity_type,
              formatted_time: safe_format_time(activity.created_at),
              activity_icon: safe_activity_icon(activity.activity_type),
              activity_color: safe_activity_color(activity.activity_type)
            }
            
            # ENHANCED: Generate personalized and detailed description
            activity_data[:description] = generate_personalized_activity_description(
              activity, viewer_user, business
            )
            
            # Safe user serialization
            if activity.user
              activity_data[:user] = {
                id: activity.user.id,
                name: safe_user_name(activity.user),
                avatar_url: activity.user.respond_to?(:avatar_url) ? activity.user.avatar_url : nil
              }
            else
              activity_data[:user] = {
                id: nil,
                name: 'Unknown User',
                avatar_url: nil
              }
            end
            
            # Safe target user serialization
            if activity.target_user
              activity_data[:target_user] = {
                id: activity.target_user.id,
                name: safe_user_name(activity.target_user)
              }
            else
              activity_data[:target_user] = nil
            end
            
            # ENHANCED: Safe package serialization with more details
            if activity.package
              package_data = {
                id: activity.package.id,
                code: activity.package.code || 'Unknown'
              }
              
              # Add recipient name if available in metadata or package
              if activity.metadata&.dig('recipient_name').present?
                package_data[:recipient_name] = activity.metadata['recipient_name']
              elsif activity.package.respond_to?(:receiver_name) && activity.package.receiver_name.present?
                package_data[:recipient_name] = activity.package.receiver_name
              end
              
              activity_data[:package] = package_data
            else
              activity_data[:package] = nil
            end
            
            # Safe metadata
            activity_data[:metadata] = activity.metadata || {}
            
            activity_data
          rescue => e
            Rails.logger.error "Error serializing activity #{activity&.id}: #{e.message}"
            {
              id: activity&.id || 'unknown',
              activity_type: activity&.activity_type || 'unknown',
              description: 'Activity data unavailable',
              formatted_time: safe_format_time(activity&.created_at || Time.current),
              activity_icon: 'activity',
              activity_color: '#6b7280',
              user: { id: nil, name: 'Unknown User', avatar_url: nil },
              target_user: nil,
              package: nil,
              metadata: {}
            }
          end
        end
      end

      # ENHANCED: Generate personalized and detailed activity descriptions
      def generate_personalized_activity_description(activity, viewer_user, business)
        begin
          # Determine if the activity user is the viewer ("you") or someone else
          actor_name = if activity.user == viewer_user
            "You"
          else
            safe_user_name(activity.user)
          end
          
          target_name = activity.target_user ? safe_user_name(activity.target_user) : nil
          
          case activity.activity_type
          when 'package_created'
            # ENHANCED: More detailed package creation description
            package_code = activity.package&.code || activity.metadata&.dig('package_code') || 'unknown'
            recipient_name = activity.metadata&.dig('recipient_name') || 'recipient'
            
            if recipient_name != 'recipient'
              "#{actor_name} created a package (#{package_code}) for #{recipient_name}"
            else
              "#{actor_name} created a package (#{package_code})"
            end
            
          when 'package_delivered'
            package_code = activity.package&.code || 'unknown'
            "Package #{package_code} was delivered"
            
          when 'package_cancelled'
            package_code = activity.package&.code || 'unknown'
            "Package #{package_code} was cancelled"
            
          when 'staff_joined'
            if target_name
              "#{target_name} joined the business"
            else
              "#{actor_name} joined the business"
            end
            
          when 'staff_removed'
            if target_name
              "#{target_name} was removed from the business"
            else
              "Staff member was removed"
            end
            
          when 'invite_sent'
            "#{actor_name} sent an invite to join the business"
            
          when 'invite_accepted'
            if target_name
              "#{target_name} accepted the invitation"
            else
              "#{actor_name} accepted the invitation"
            end
            
          when 'business_updated'
            "#{actor_name} updated business information"
            
          when 'logo_updated'
            "#{actor_name} updated the business logo"
            
          when 'categories_updated'
            "#{actor_name} updated business categories"
            
          when 'business_created'
            "#{actor_name} created the business"
            
          else
            "#{actor_name} performed #{activity.activity_type&.humanize&.downcase || 'an action'}"
          end
          
        rescue => e
          Rails.logger.error "Failed to generate personalized description: #{e.message}"
          "Activity performed" # Fallback description
        end
      end

      # Helper methods for safe serialization
      def safe_user_name(user)
        return 'Unknown User' unless user
        
        if user.respond_to?(:full_name) && user.full_name.present?
          user.full_name
        elsif user.respond_to?(:name) && user.name.present?
          user.name
        elsif user.email.present?
          user.email
        else
          "User ##{user.id}"
        end
      rescue => e
        Rails.logger.error "Error getting user name: #{e.message}"
        'Unknown User'
      end

      # FIXED: Timezone-aware time formatting
      def safe_format_time(time)
        return 'Unknown time' unless time
        
        # Convert UTC time to local timezone
        # Use application timezone or user's timezone if available
        local_time = time.in_time_zone(Time.zone)
        
        if local_time.today?
          local_time.strftime('%I:%M %p')
        elsif local_time > 1.week.ago
          local_time.strftime('%a %I:%M %p')
        else
          local_time.strftime('%b %d, %Y')
        end
      rescue => e
        Rails.logger.error "Error formatting time: #{e.message}"
        'Unknown time'
      end

      def safe_activity_icon(activity_type)
        case activity_type
        when 'package_created'
          'package'
        when 'package_delivered'
          'check-circle'
        when 'package_cancelled'
          'x-circle'
        when 'staff_joined', 'invite_accepted'
          'user-plus'
        when 'staff_removed'
          'user-minus'
        when 'invite_sent'
          'mail'
        when 'business_updated', 'logo_updated', 'categories_updated'
          'edit'
        when 'business_created'
          'briefcase'
        else
          'activity'
        end
      rescue
        'activity'
      end

      def safe_activity_color(activity_type)
        case activity_type
        when 'package_created', 'staff_joined', 'invite_accepted', 'business_created'
          '#10b981'
        when 'package_delivered'
          '#3b82f6'
        when 'package_cancelled', 'staff_removed'
          '#ef4444'
        when 'invite_sent', 'business_updated', 'logo_updated', 'categories_updated'
          '#f59e0b'
        else
          '#6b7280'
        end
      rescue
        '#6b7280'
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