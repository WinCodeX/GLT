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
            # Pagination
            page = [params[:page].to_i, 1].max
            per_page = [params[:per_page].to_i, 20].max.clamp(1, 100)
            offset = (page - 1) * per_page

            # Start with base query - FIXED: Build complete query first, then paginate
            @notifications = Notification.includes(:user, :package)

            # Apply filters BEFORE pagination
            @notifications = @notifications.where(notification_type: params[:type]) if params[:type].present?
            @notifications = @notifications.where(status: params[:status]) if params[:status].present?
            @notifications = @notifications.where(priority: params[:priority]) if params[:priority].present?
            @notifications = @notifications.where(read: params[:read] == 'true') if params[:read].present?

            # Search filter - FIXED: Handle joins properly
            if params[:search].present?
              search_term = "%#{params[:search]}%"
              @notifications = @notifications.joins(:user)
                                           .where(
                                             "notifications.title ILIKE ? OR notifications.message ILIKE ? OR users.name ILIKE ?",
                                             search_term, search_term, search_term
                                           )
            end

            # Get total count BEFORE applying pagination - FIXED: Count the filtered query
            total_count = @notifications.count
            total_pages = (total_count.to_f / per_page).ceil

            # FIXED: Apply pagination AFTER building the complete filtered query
            @notifications = @notifications.order(created_at: :desc)
                                          .offset(offset)
                                          .limit(per_page)

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
            Rails.logger.error "Admin::NotificationsController#index error: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
            
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
            total_notifications = Notification.count
            unread_notifications = Notification.where(read: false).count
            delivered_notifications = Notification.where(delivered: true).count
            pending_notifications = Notification.where(status: 'pending').count
            expired_notifications = Notification.where('expires_at <= ?', Time.current).count

            # Group by notification type
            by_type = Notification.group(:notification_type).count

            # Group by priority
            by_priority = Notification.group(:priority).count

            # Group by status
            by_status = Notification.group(:status).count

            # Recent activity (last 7 days) - FIXED: Handle gracefully without groupdate
            recent_activity = {}
            begin
              # Simple daily count for the last 7 days without groupdate dependency
              7.downto(0) do |days_ago|
                date = days_ago.days.ago.beginning_of_day
                date_end = date.end_of_day
                count = Notification.where(created_at: date..date_end).count
                recent_activity[date.strftime('%Y-%m-%d')] = count
              end
            rescue => e
              Rails.logger.warn "Could not generate recent activity stats: #{e.message}"
              recent_activity = {}
            end

            render json: {
              success: true,
              data: {
                total: total_notifications,
                unread: unread_notifications,
                delivered: delivered_notifications,
                pending: pending_notifications,
                expired: expired_notifications,
                by_type: by_type,
                by_priority: by_priority,
                by_status: by_status,
                recent_activity: recent_activity
              }
            }, status: :ok
          rescue => e
            Rails.logger.error "Admin::NotificationsController#stats error: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
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
            Rails.logger.error "Admin::NotificationsController#create error: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
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
            Rails.logger.error "Admin::NotificationsController#mark_as_read error: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
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
            Rails.logger.error "Admin::NotificationsController#mark_as_unread error: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
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
            Rails.logger.error "Admin::NotificationsController#destroy error: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
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
              User.all # Broadcast to all users
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
            Rails.logger.error "Admin::NotificationsController#broadcast error: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
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
          unless current_user&.role == 'admin'
            render json: {
              success: false,
              message: 'Access denied. Admin privileges required.'
            }, status: :forbidden
          end
        end

        # Enhanced serialization for admin view - FIXED: Handle nil values properly
        def serialize_admin_notification(notification)
          result = {
            id: notification.id,
            title: notification.title || '',
            message: notification.message || '',
            notification_type: notification.notification_type || 'general',
            priority: notification.priority || 0,
            read: !!notification.read,
            delivered: !!notification.delivered,
            status: notification.status || 'pending',
            channel: notification.channel || 'in_app',
            created_at: notification.created_at&.iso8601,
            read_at: notification.read_at&.iso8601,
            delivered_at: notification.delivered_at&.iso8601,
            expires_at: notification.expires_at&.iso8601,
            action_url: notification.action_url,
            icon: notification.icon || 'notifications',
            metadata: notification.try(:metadata) || {}
          }

          # Add user information - FIXED: Handle cases where user might be nil
          if notification.user
            result[:user] = {
              id: notification.user.id,
              name: notification.user.name || 'Unknown User',
              email: notification.user.email,
              phone: notification.user.phone,
              role: notification.user.role || 'user'
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

          # Add package information if present - FIXED: Handle nil package
          if notification.package
            result[:package] = {
              id: notification.package.id,
              code: notification.package.code,
              state: notification.package.state
            }
          end

          # Add computed fields - FIXED: Use safe navigation and handle missing methods
          if notification.created_at
            begin
              result[:formatted_created_at] = notification.created_at.strftime('%B %d, %Y at %I:%M %p')
              # Use simple time calculation instead of Rails helper that might not be available
              time_diff = Time.current - notification.created_at
              if time_diff < 1.minute
                result[:time_since_creation] = 'just now'
              elsif time_diff < 1.hour
                result[:time_since_creation] = "#{(time_diff / 1.minute).round} minutes ago"
              elsif time_diff < 1.day
                result[:time_since_creation] = "#{(time_diff / 1.hour).round} hours ago"
              else
                result[:time_since_creation] = "#{(time_diff / 1.day).round} days ago"
              end
            rescue => e
              Rails.logger.warn "Error formatting notification times: #{e.message}"
              result[:formatted_created_at] = notification.created_at.to_s
              result[:time_since_creation] = 'unknown'
            end
          end

          result[:expired] = notification.expires_at ? notification.expires_at <= Time.current : false

          result
        end
      end
    end
  end
end