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

            # Build base query with safe includes
            base_query = Notification.includes(:user, :package)

            # Apply filters safely
            filtered_query = apply_filters(base_query)
            
            # Get total count before pagination
            total_count = filtered_query.count
            total_pages = (total_count.to_f / per_page).ceil
            
            # Apply pagination and ordering
            @notifications = filtered_query.order(created_at: :desc)
                                          .offset((page - 1) * per_page)
                                          .limit(per_page)

            Rails.logger.info "Found #{@notifications.count} notifications (#{total_count} total)"

            render json: {
              success: true,
              data: @notifications.map { |notification| serialize_admin_notification(notification) },
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
                data: serialize_admin_notification(@notification)
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
              data: serialize_admin_notification(@notification)
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
              data: serialize_admin_notification(@notification)
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

          # Search filter - be careful with joins
          if params[:search].present?
            search_term = "%#{params[:search].downcase}%"
            query = query.joins(:user).where(
              "LOWER(notifications.title) LIKE ? OR LOWER(notifications.message) LIKE ? OR LOWER(users.name) LIKE ?",
              search_term, search_term, search_term
            )
          end

          query
        end

        # Safe serialization that handles all edge cases
        def serialize_admin_notification(notification)
          begin
            result = {
              id: notification.id,
              title: safe_string(notification.title),
              message: safe_string(notification.message),
              notification_type: safe_string(notification.notification_type, 'general'),
              priority: safe_integer(notification.priority, 0),
              read: !!notification.read,
              delivered: !!notification.delivered,
              status: safe_string(notification.status, 'pending'),
              channel: safe_string(notification.channel, 'in_app'),
              created_at: safe_datetime(notification.created_at),
              read_at: safe_datetime(notification.read_at),
              delivered_at: safe_datetime(notification.delivered_at),
              expires_at: safe_datetime(notification.expires_at),
              action_url: notification.action_url,
              icon: safe_string(notification.icon, 'notifications'),
              metadata: safe_json(notification.metadata)
            }

            # Add user information safely
            if notification.user
              result[:user] = {
                id: notification.user.id,
                name: safe_string(notification.user.name, 'Unknown User'),
                email: notification.user.email,
                phone: notification.user.phone,
                role: safe_string(notification.user.role, 'user')
              }
            else
              result[:user] = {
                id: nil,
                name: 'System',
                email: nil,
                phone: nil,
                role: 'system'
              }
            end

            # Add package information if present
            if notification.package
              result[:package] = {
                id: notification.package.id,
                code: safe_string(notification.package.code),
                state: safe_string(notification.package.state)
              }
            end

            # Add computed fields safely
            if notification.created_at
              result[:formatted_created_at] = format_datetime(notification.created_at)
              result[:time_since_creation] = time_ago_text(notification.created_at)
            else
              result[:formatted_created_at] = 'Unknown date'
              result[:time_since_creation] = 'Unknown'
            end

            result[:expired] = notification.expires_at ? notification.expires_at <= Time.current : false

            result
          rescue => e
            Rails.logger.error "Error serializing notification #{notification.id}: #{e.message}"
            
            # Return minimal safe data if serialization fails
            {
              id: notification.id,
              title: 'Error loading notification',
              message: 'Unable to load notification details',
              notification_type: 'general',
              priority: 0,
              read: false,
              delivered: false,
              status: 'error',
              channel: 'in_app',
              created_at: Time.current.iso8601,
              expired: false,
              user: { id: nil, name: 'Unknown', role: 'unknown' }
            }
          end
        end

        # Helper methods for safe data handling
        def safe_string(value, default = '')
          value.to_s.presence || default
        end

        def safe_integer(value, default = 0)
          value.to_i || default
        end

        def safe_datetime(value)
          value&.iso8601
        end

        def safe_json(value)
          case value
          when Hash
            value
          when String
            begin
              JSON.parse(value)
            rescue JSON::ParserError
              {}
            end
          else
            {}
          end
        end

        def format_datetime(datetime)
          datetime.strftime('%B %d, %Y at %I:%M %p')
        rescue
          datetime.to_s
        end

        # Custom time ago implementation that doesn't rely on view helpers
        def time_ago_text(time)
          return 'Unknown' unless time
          
          time_diff = Time.current - time
          
          case time_diff
          when 0..59
            'just now'
          when 60..3599
            minutes = (time_diff / 60).round
            "#{minutes} minute#{'s' if minutes != 1} ago"
          when 3600..86399
            hours = (time_diff / 3600).round
            "#{hours} hour#{'s' if hours != 1} ago"
          when 86400..2591999
            days = (time_diff / 86400).round
            "#{days} day#{'s' if days != 1} ago"
          else
            time.strftime('%b %d, %Y')
          end
        rescue
          'Unknown'
        end
      end
    end
  end
end