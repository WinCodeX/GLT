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

            # Base query - all notifications across all users
            @notifications = Notification.includes(:user, :package)
                                       .order(created_at: :desc)
                                       .offset(offset)
                                       .limit(per_page)

            # Apply filters
            @notifications = @notifications.where(notification_type: params[:type]) if params[:type].present?
            @notifications = @notifications.where(status: params[:status]) if params[:status].present?
            @notifications = @notifications.where(priority: params[:priority]) if params[:priority].present?
            @notifications = @notifications.where(read: params[:read] == 'true') if params[:read].present?

            # Search filter
            if params[:search].present?
              search_term = "%#{params[:search]}%"
              @notifications = @notifications.joins(:user)
                                           .where(
                                             "notifications.title ILIKE ? OR notifications.message ILIKE ? OR users.name ILIKE ?",
                                             search_term, search_term, search_term
                                           )
            end

            # Get total count for pagination
            total_count = @notifications.except(:offset, :limit, :order).count
            total_pages = (total_count.to_f / per_page).ceil

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

            # Recent activity (last 7 days) - handle if groupdate is not available
            recent_activity = begin
              if Notification.respond_to?(:group_by_day)
                Notification.where('created_at >= ?', 7.days.ago)
                           .group_by_day(:created_at)
                           .count
              else
                # Fallback if groupdate gem is not available
                {}
              end
            rescue
              {}
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
            render json: {
              success: false,
              message: 'Failed to create notification',
              error: Rails.env.development? ? e.message : 'Internal server error'
            }, status: :internal_server_error
          end
        end

        # PATCH /api/v1/admin/notifications/:id/mark_as_read
        def mark_as_read
          @notification.update!(read: true, read_at: Time.current)
          
          render json: {
            success: true,
            message: 'Notification marked as read',
            data: serialize_admin_notification(@notification)
          }, status: :ok
        rescue => e
          Rails.logger.error "Admin::NotificationsController#mark_as_read error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to mark notification as read',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end

        # PATCH /api/v1/admin/notifications/:id/mark_as_unread
        def mark_as_unread
          @notification.update!(read: false, read_at: nil)
          
          render json: {
            success: true,
            message: 'Notification marked as unread',
            data: serialize_admin_notification(@notification)
          }, status: :ok
        rescue => e
          Rails.logger.error "Admin::NotificationsController#mark_as_unread error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to mark notification as unread',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end

        # DELETE /api/v1/admin/notifications/:id
        def destroy
          @notification.destroy!
          
          render json: {
            success: true,
            message: 'Notification deleted successfully'
          }, status: :ok
        rescue => e
          Rails.logger.error "Admin::NotificationsController#destroy error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to delete notification',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
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
          unless current_user.role == 'admin'
            render json: {
              success: false,
              message: 'Access denied. Admin privileges required.'
            }, status: :forbidden
          end
        end

        # Enhanced serialization for admin view
        def serialize_admin_notification(notification)
          result = {
            id: notification.id,
            title: notification.title,
            message: notification.message,
            notification_type: notification.notification_type,
            priority: notification.priority,
            read: !!notification.read,
            delivered: !!notification.delivered,
            status: notification.status,
            channel: notification.channel,
            created_at: notification.created_at&.iso8601,
            read_at: notification.read_at&.iso8601,
            delivered_at: notification.delivered_at&.iso8601,
            expires_at: notification.expires_at&.iso8601,
            action_url: notification.action_url,
            icon: notification.icon || 'notifications',
            metadata: notification.metadata || {}
          }

          # Add user information
          if notification.user
            result[:user] = {
              id: notification.user.id,
              name: notification.user.name,
              email: notification.user.email,
              phone: notification.user.phone,
              role: notification.user.role
            }
          end

          # Add package information if present
          if notification.package
            result[:package] = {
              id: notification.package.id,
              code: notification.package.code,
              state: notification.package.state
            }
          end

          # Add computed fields
          if notification.created_at
            result[:formatted_created_at] = notification.created_at.strftime('%B %d, %Y at %I:%M %p')
            result[:time_since_creation] = time_ago_in_words(notification.created_at)
          end

          result[:expired] = notification.expires_at ? notification.expires_at <= Time.current : false

          result
        end
      end
    end
  end
end