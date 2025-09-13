# app/controllers/api/v1/admin/notifications_controller.rb
module Api
  module V1
    module Admin
      class NotificationsController < ApplicationController
        before_action :authenticate_user!
        before_action :ensure_admin_user!
        before_action :set_notification, only: [:show, :mark_as_read, :mark_as_unread, :destroy]
        
        respond_to :json

        # GET /api/v1/admin/notifications
        def index
          begin
            Rails.logger.info "Admin notifications index called by user #{current_user.id}"
            
            # Pagination parameters
            page = [params[:page].to_i, 1].max
            per_page = [params[:per_page].to_i, 20].max.clamp(1, 100)

            # Build base query with left joins to handle missing associations
            base_query = Notification.left_joins(:user, :package)

            # Apply filters safely
            filtered_query = apply_filters(base_query)
            
            # Get total count before pagination
            total_count = filtered_query.count
            total_pages = (total_count.to_f / per_page).ceil
            
            # Apply pagination and ordering - include all fields to avoid N+1
            @notifications = filtered_query.select('notifications.*, users.name as user_name, users.email as user_email, users.phone as user_phone, users.role as user_role, packages.code as package_code, packages.state as package_state')
                                          .order('notifications.created_at DESC')
                                          .offset((page - 1) * per_page)
                                          .limit(per_page)

            Rails.logger.info "Found #{@notifications.count} notifications (#{total_count} total)"

            # Serialize safely
            serialized_data = @notifications.map do |notification|
              serialize_admin_notification_safe(notification)
            end.compact # Remove any nil results

            render json: {
              success: true,
              data: serialized_data,
              pagination: {
                current_page: page,
                total_pages: total_pages,
                total_count: total_count,
                per_page: per_page
              }
            }, status: :ok
            
          rescue => e
            Rails.logger.error "Admin::NotificationsController#index error: #{e.class}: #{e.message}"
            Rails.logger.error e.backtrace.first(10).join("\n")
            
            render json: {
              success: false,
              message: 'Failed to fetch notifications',
              error: Rails.env.development? ? e.message : 'Internal server error'
            }, status: :internal_server_error
          end
        end

        # GET /api/v1/admin/notifications/stats
        def stats
          begin
            Rails.logger.info "Admin notifications stats called by user #{current_user.id}"
            
            # Use raw SQL counts to avoid potential enum issues
            stats_data = {
              total: Notification.count,
              unread: Notification.where(read: false).count,
              delivered: Notification.where(delivered: true).count,
              pending: Notification.where("status = 'pending' OR status IS NULL").count,
              expired: Notification.where('expires_at <= ?', Time.current).count
            }

            # Group by type - using string values to avoid enum issues
            by_type = Notification.group(:notification_type).count
            
            # Group by priority - convert to integer keys for consistency
            by_priority_raw = Notification.group(:priority).count
            by_priority = {}
            by_priority_raw.each do |priority, count|
              key = case priority.to_i
                   when 2 then 'urgent'
                   when 1 then 'high' 
                   else 'normal'
                   end
              by_priority[key] = count
            end

            # Group by status
            by_status = Notification.group(:status).count

            # Recent activity (simple approach)
            recent_activity = {}
            7.downto(0) do |days_ago|
              date = days_ago.days.ago.beginning_of_day
              date_end = date.end_of_day
              count = Notification.where(created_at: date..date_end).count
              recent_activity[date.strftime('%Y-%m-%d')] = count
            end

            render json: {
              success: true,
              data: stats_data.merge({
                by_type: by_type,
                by_priority: by_priority,
                by_status: by_status,
                recent_activity: recent_activity
              })
            }, status: :ok
            
          rescue => e
            Rails.logger.error "Admin::NotificationsController#stats error: #{e.class}: #{e.message}"
            Rails.logger.error e.backtrace.first(10).join("\n")
            
            render json: {
              success: false,
              message: 'Failed to fetch notification statistics',
              error: Rails.env.development? ? e.message : 'Internal server error'
            }, status: :internal_server_error
          end
        end

        # POST /api/v1/admin/notifications
        def create
          begin
            notification_params = params.require(:notification).permit(
              :title, :message, :notification_type, :priority, :channel, 
              :expires_at, :action_url, :icon, :user_id, :package_id,
              metadata: {}
            )

            @notification = Notification.new(notification_params)
            
            if @notification.save
              render json: {
                success: true,
                message: 'Notification created successfully',
                data: serialize_admin_notification_safe(@notification)
              }, status: :created
            else
              render json: {
                success: false,
                message: 'Failed to create notification',
                errors: @notification.errors.full_messages
              }, status: :unprocessable_entity
            end
            
          rescue => e
            Rails.logger.error "Admin::NotificationsController#create error: #{e.class}: #{e.message}"
            Rails.logger.error e.backtrace.first(10).join("\n")
            
            render json: {
              success: false,
              message: 'Failed to create notification',
              error: Rails.env.development? ? e.message : 'Internal server error'
            }, status: :internal_server_error
          end
        end

        # PATCH /api/v1/admin/notifications/:id/mark_as_read
        def mark_as_read
          begin
            @notification.update!(read: true, read_at: Time.current)
            
            render json: {
              success: true,
              message: 'Notification marked as read',
              data: serialize_admin_notification_safe(@notification)
            }, status: :ok
            
          rescue => e
            Rails.logger.error "Admin::NotificationsController#mark_as_read error: #{e.class}: #{e.message}"
            
            render json: {
              success: false,
              message: 'Failed to mark notification as read',
              error: Rails.env.development? ? e.message : 'Internal server error'
            }, status: :internal_server_error
          end
        end

        # PATCH /api/v1/admin/notifications/:id/mark_as_unread
        def mark_as_unread
          begin
            @notification.update!(read: false, read_at: nil)
            
            render json: {
              success: true,
              message: 'Notification marked as unread',
              data: serialize_admin_notification_safe(@notification)
            }, status: :ok
            
          rescue => e
            Rails.logger.error "Admin::NotificationsController#mark_as_unread error: #{e.class}: #{e.message}"
            
            render json: {
              success: false,
              message: 'Failed to mark notification as unread',
              error: Rails.env.development? ? e.message : 'Internal server error'
            }, status: :internal_server_error
          end
        end

        # DELETE /api/v1/admin/notifications/:id
        def destroy
          begin
            @notification.destroy!
            
            render json: {
              success: true,
              message: 'Notification deleted successfully'
            }, status: :ok
            
          rescue => e
            Rails.logger.error "Admin::NotificationsController#destroy error: #{e.class}: #{e.message}"
            
            render json: {
              success: false,
              message: 'Failed to delete notification',
              error: Rails.env.development? ? e.message : 'Internal server error'
            }, status: :internal_server_error
          end
        end

        # POST /api/v1/admin/notifications/broadcast
        def broadcast
          begin
            broadcast_params = params.require(:broadcast).permit(
              :title, :message, :notification_type, :priority, :channel,
              :expires_at, :action_url, :icon, user_ids: [], metadata: {}
            )

            # Determine target users
            target_users = if broadcast_params[:user_ids].present?
              User.where(id: broadcast_params[:user_ids])
            else
              User.all
            end

            notifications_created = 0
            
            target_users.find_each do |user|
              notification = user.notifications.create!(
                title: broadcast_params[:title],
                message: broadcast_params[:message],
                notification_type: broadcast_params[:notification_type] || 'general',
                priority: broadcast_params[:priority] || 0,
                channel: broadcast_params[:channel] || 'in_app',
                expires_at: broadcast_params[:expires_at],
                action_url: broadcast_params[:action_url],
                icon: broadcast_params[:icon] || 'notifications',
                metadata: broadcast_params[:metadata] || {}
              )
              notifications_created += 1
            end

            render json: {
              success: true,
              message: "Broadcast sent to #{notifications_created} users",
              data: {
                notifications_created: notifications_created,
                target_users_count: target_users.count
              }
            }, status: :created
            
          rescue => e
            Rails.logger.error "Admin::NotificationsController#broadcast error: #{e.class}: #{e.message}"
            Rails.logger.error e.backtrace.first(10).join("\n")
            
            render json: {
              success: false,
              message: 'Failed to broadcast notification',
              error: Rails.env.development? ? e.message : 'Internal server error'
            }, status: :internal_server_error
          end
        end

        private

        def set_notification
          @notification = Notification.find_by!(id: params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: {
            success: false,
            message: 'Notification not found'
          }, status: :not_found
        end

        def ensure_admin_user!
          unless current_user&.admin?
            Rails.logger.warn "Non-admin user #{current_user&.id} attempted to access admin notifications"
            render json: {
              success: false,
              message: 'Access denied. Admin privileges required.'
            }, status: :forbidden
          end
        end

        def apply_filters(base_query)
          query = base_query

          # Type filter - handle both string and symbol enum values
          if params[:type].present?
            query = query.where(notification_type: params[:type])
          end

          # Status filter
          if params[:status].present?
            query = query.where(status: params[:status])
          end

          # Priority filter - handle integer values
          if params[:priority].present?
            query = query.where(priority: params[:priority].to_i)
          end

          # Read status filter
          if params[:read].present?
            read_value = params[:read] == 'true'
            query = query.where(read: read_value)
          end

          # FIXED: Search filter with safer LEFT JOIN approach
          if params[:search].present?
            search_term = "%#{params[:search].downcase}%"
            query = query.where(
              "LOWER(notifications.title) LIKE ? OR LOWER(notifications.message) LIKE ? OR LOWER(COALESCE(users.name, '')) LIKE ?",
              search_term, search_term, search_term
            )
          end

          query
        end

        # COMPLETELY REWRITTEN: Ultra-safe serialization that prevents all errors
        def serialize_admin_notification_safe(notification)
          return nil unless notification&.id

          begin
            # Build base notification data with safe fallbacks
            result = {
              id: notification.id.to_i,
              title: safe_string_value(notification.title, 'Untitled Notification'),
              message: safe_string_value(notification.message, 'No message content'),
              notification_type: safe_string_value(notification.notification_type, 'general'),
              priority: safe_integer_value(notification.priority, 0),
              read: !!notification.read,
              delivered: !!notification.delivered,
              status: safe_string_value(notification.status, 'pending'),
              channel: safe_string_value(notification.channel, 'in_app'),
              created_at: safe_iso8601(notification.created_at),
              read_at: safe_iso8601(notification.read_at),
              delivered_at: safe_iso8601(notification.delivered_at),
              expires_at: safe_iso8601(notification.expires_at),
              action_url: notification.action_url,
              icon: safe_string_value(notification.icon, 'bell'),
              metadata: safe_metadata(notification.metadata)
            }

            # FIXED: Handle user data from joined query or association
            user_data = extract_user_data(notification)
            result[:user] = user_data

            # FIXED: Handle package data from joined query or association
            package_data = extract_package_data(notification)
            result[:package] = package_data if package_data

            # Add computed time fields safely
            result[:time_since_creation] = safe_time_ago(notification.created_at)
            result[:formatted_created_at] = safe_formatted_date(notification.created_at)
            result[:expired] = notification.expires_at ? (notification.expires_at <= Time.current) : false

            result
          rescue => e
            Rails.logger.error "Critical error serializing notification #{notification.id}: #{e.class}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            
            # Return absolute minimal safe data
            {
              id: notification.id.to_i,
              title: 'Error Loading Notification',
              message: 'This notification could not be loaded properly',
              notification_type: 'general',
              priority: 0,
              read: false,
              delivered: false,
              status: 'error',
              channel: 'in_app',
              created_at: Time.current.iso8601,
              time_since_creation: 'Unknown',
              formatted_created_at: 'Unknown date',
              expired: false,
              user: {
                id: nil,
                name: 'System',
                email: nil,
                phone: nil,
                role: 'system'
              }
            }
          end
        end

        # FIXED: Extract user data from either joined query or association
        def extract_user_data(notification)
          # Try to get user data from joined query attributes first
          if notification.respond_to?(:user_name) && notification.user_name
            return {
              id: notification.user_id,
              name: safe_string_value(notification.user_name, 'Unknown User'),
              email: notification.respond_to?(:user_email) ? notification.user_email : nil,
              phone: notification.respond_to?(:user_phone) ? notification.user_phone : nil,
              role: notification.respond_to?(:user_role) ? safe_string_value(notification.user_role, 'user') : 'user'
            }
          end

          # Fallback to association if available
          if notification.user_id && notification.respond_to?(:user) && notification.user
            return {
              id: notification.user.id,
              name: safe_string_value(notification.user.name, 'Unknown User'),
              email: notification.user.email,
              phone: notification.user.phone,
              role: safe_string_value(notification.user.role, 'user')
            }
          end

          # Return system user for orphaned notifications
          {
            id: nil,
            name: 'System',
            email: nil,
            phone: nil,
            role: 'system'
          }
        end

        # FIXED: Extract package data from either joined query or association
        def extract_package_data(notification)
          # Try to get package data from joined query attributes first
          if notification.respond_to?(:package_code) && notification.package_code
            return {
              id: notification.package_id,
              code: safe_string_value(notification.package_code),
              state: notification.respond_to?(:package_state) ? safe_string_value(notification.package_state) : nil
            }
          end

          # Fallback to association if available
          if notification.package_id && notification.respond_to?(:package) && notification.package
            return {
              id: notification.package.id,
              code: safe_string_value(notification.package.code),
              state: safe_string_value(notification.package.state)
            }
          end

          # Check metadata for package info (for deleted packages)
          if notification.package_id && notification.metadata.is_a?(Hash)
            package_code = notification.metadata['package_code'] || notification.metadata[:package_code]
            if package_code
              return {
                id: notification.package_id,
                code: package_code.to_s,
                state: 'deleted'
              }
            end
          end

          nil
        end

        # Ultra-safe helper methods
        def safe_string_value(value, default = '')
          return default if value.nil?
          
          str = value.to_s.strip
          str.empty? ? default : str
        rescue
          default
        end

        def safe_integer_value(value, default = 0)
          return default if value.nil?
          
          value.to_i
        rescue
          default
        end

        def safe_iso8601(datetime)
          return nil if datetime.nil?
          
          datetime.iso8601
        rescue
          nil
        end

        def safe_metadata(metadata)
          case metadata
          when Hash
            metadata
          when String
            begin
              JSON.parse(metadata)
            rescue JSON::ParserError
              {}
            end
          when nil
            {}
          else
            {}
          end
        rescue
          {}
        end

        def safe_time_ago(time)
          return 'Unknown' if time.nil?
          
          time_diff = Time.current - time
          
          case time_diff
          when 0..59
            'just now'
          when 60..3599
            minutes = (time_diff / 60).round
            "#{minutes}m ago"
          when 3600..86399
            hours = (time_diff / 3600).round
            "#{hours}h ago"
          when 86400..2591999
            days = (time_diff / 86400).round
            "#{days}d ago"
          else
            time.strftime('%b %d')
          end
        rescue
          'Unknown'
        end

        def safe_formatted_date(datetime)
          return 'Unknown date' if datetime.nil?
          
          datetime.strftime('%B %d, %Y at %I:%M %p')
        rescue
          datetime.to_s
        rescue
          'Unknown date'
        end
      end
    end
  end
end