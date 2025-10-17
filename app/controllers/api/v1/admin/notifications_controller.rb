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
            
            page = [params[:page].to_i, 1].max
            per_page = [params[:per_page].to_i, 20].max.clamp(1, 100)
            offset = (page - 1) * per_page

            @notifications = Notification.order(created_at: :desc)
                                        .offset(offset)
                                        .limit(per_page)

            total_count = Notification.count
            total_pages = (total_count.to_f / per_page).ceil

            Rails.logger.info "Found #{@notifications.count} notifications (#{total_count} total)"

            render json: {
              success: true,
              data: @notifications.map { |notification| simple_serialize(notification) },
              pagination: {
                current_page: page,
                total_pages: total_pages,
                total_count: total_count,
                per_page: per_page
              }
            }, status: :ok
            
          rescue => e
            Rails.logger.error "Admin::NotificationsController#index error: #{e.message}"
            
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
            stats_data = {
              total: Notification.count,
              unread: Notification.where(read: false).count,
              delivered: Notification.where(delivered: true).count,
              pending: Notification.where(status: 'pending').count,
              expired: Notification.where('expires_at <= ?', Time.current).count
            }

            by_type = Notification.group(:notification_type).count
            by_priority = Notification.group(:priority).count
            by_status = Notification.group(:status).count

            render json: {
              success: true,
              data: stats_data.merge({
                by_type: by_type,
                by_priority: by_priority,
                by_status: by_status
              })
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
              :expires_at, :action_url, :icon, :user_id, :package_id
            )
            
            send_push = params.dig(:notification, :send_push_notification) != false

            @notification = Notification.new(notification_params)
            
            if @notification.save
              Rails.logger.info "📝 Created notification #{@notification.id} for user #{@notification.user_id}"
              
              if send_push && should_send_push_notification?(@notification)
                send_push_notification_async(@notification)
              end
              
              render json: {
                success: true,
                message: 'Notification created successfully',
                data: simple_serialize(@notification).merge({
                  push_sent: send_push && @notification.user&.push_tokens&.active&.any?
                })
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
          
          # Broadcast notification read status
          broadcast_notification_read(@notification)
          
          render json: {
            success: true,
            message: 'Notification marked as read',
            data: simple_serialize(@notification)
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
          
          # Broadcast notification unread status
          broadcast_notification_unread(@notification)
          
          render json: {
            success: true,
            message: 'Notification marked as unread',
            data: simple_serialize(@notification)
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
              :expires_at, :action_url, :icon, user_ids: []
            )
            
            send_push = params.dig(:broadcast, :send_push_notification) != false

            target_users = if broadcast_params[:user_ids].present?
              User.where(id: broadcast_params[:user_ids])
            else
              User.all
            end

            notifications_created = 0
            push_notifications_sent = 0
            created_notifications = []
            
            target_users.find_each do |user|
              notification = user.notifications.create!(
                title: broadcast_params[:title],
                message: broadcast_params[:message],
                notification_type: broadcast_params[:notification_type] || 'general',
                priority: broadcast_params[:priority] || 0,
                channel: broadcast_params[:channel] || 'in_app',
                expires_at: broadcast_params[:expires_at],
                action_url: broadcast_params[:action_url],
                icon: broadcast_params[:icon] || 'bell'
              )
              
              notifications_created += 1
              created_notifications << notification
              
              if send_push && should_send_push_notification?(notification)
                send_push_notification_async(notification)
                push_notifications_sent += 1
              end
            end

            Rails.logger.info "📢 Broadcast completed: #{notifications_created} notifications created, #{push_notifications_sent} push notifications sent"

            render json: {
              success: true,
              message: "Broadcast sent to #{notifications_created} users",
              data: {
                notifications_created: notifications_created,
                push_notifications_sent: push_notifications_sent,
                target_users_count: target_users.count,
                push_enabled: send_push
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

        # POST /api/v1/admin/notifications/:id/resend_push
        def resend_push
          begin
            @notification = Notification.find(params[:id])
            
            if should_send_push_notification?(@notification)
              send_push_notification_async(@notification)
              
              render json: {
                success: true,
                message: 'Push notification resent successfully',
                data: simple_serialize(@notification)
              }, status: :ok
            else
              render json: {
                success: false,
                message: 'Cannot send push notification - user has no active push tokens'
              }, status: :unprocessable_entity
            end
            
          rescue ActiveRecord::RecordNotFound
            render json: {
              success: false,
              message: 'Notification not found'
            }, status: :not_found
          rescue => e
            Rails.logger.error "Admin::NotificationsController#resend_push error: #{e.message}"
            
            render json: {
              success: false,
              message: 'Failed to resend push notification',
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
            render json: {
              success: false,
              message: 'Access denied. Admin privileges required.'
            }, status: :forbidden
          end
        end

        def should_send_push_notification?(notification)
          return false unless notification.user
          return false unless notification.user.push_tokens.active.any?
          
          true
        end

        def send_push_notification_async(notification)
          begin
            Rails.logger.info "🚀 Sending push notification for notification #{notification.id}"
            
            PushNotificationService.new.send_immediate(notification)
            
            Rails.logger.info "✅ Push notification sent for notification #{notification.id}"
            
          rescue => e
            Rails.logger.error "❌ Failed to send push notification for notification #{notification.id}: #{e.message}"
          end
        end

        def broadcast_notification_read(notification)
          return unless notification.user_id

          ActionCable.server.broadcast(
            "user_notifications_#{notification.user_id}",
            {
              type: 'notification_read',
              notification_id: notification.id,
              user_id: notification.user_id,
              timestamp: Time.current.iso8601
            }
          )

          Rails.logger.info "📡 Broadcasted notification_read for notification #{notification.id}"
        end

        def broadcast_notification_unread(notification)
          return unless notification.user_id

          ActionCable.server.broadcast(
            "user_notifications_#{notification.user_id}",
            {
              type: 'notification_unread',
              notification_id: notification.id,
              user_id: notification.user_id,
              timestamp: Time.current.iso8601
            }
          )

          Rails.logger.info "📡 Broadcasted notification_unread for notification #{notification.id}"
        end

        def simple_serialize(notification)
          {
            id: notification.id,
            title: notification.title || 'Untitled Notification',
            message: notification.message || 'No message content',
            notification_type: notification.notification_type || 'general',
            priority: notification.priority || 0,
            read: !!notification.read,
            delivered: !!notification.delivered,
            status: notification.status || 'pending',
            created_at: notification.created_at&.iso8601,
            expires_at: notification.expires_at&.iso8601,
            icon: notification.icon || 'bell',
            action_url: notification.action_url,
            expired: notification.expires_at ? notification.expires_at <= Time.current : false,
            user: get_user_info(notification),
            package: get_package_info(notification),
            time_since_creation: time_ago(notification.created_at),
            formatted_created_at: format_date(notification.created_at)
          }
        end

        def get_user_info(notification)
          if notification.user_id
            user = User.find_by(id: notification.user_id)
            if user
              {
                id: user.id,
                name: user.name || 'Unknown User',
                email: user.email,
                phone: user.phone,
                role: user.role || 'user',
                has_push_tokens: user.push_tokens.active.any?
              }
            else
              {
                id: nil,
                name: 'Deleted User',
                email: nil,
                phone: nil,
                role: 'deleted',
                has_push_tokens: false
              }
            end
          else
            {
              id: nil,
              name: 'System',
              email: nil,
              phone: nil,
              role: 'system',
              has_push_tokens: false
            }
          end
        rescue
          {
            id: nil,
            name: 'Unknown',
            email: nil,
            phone: nil,
            role: 'unknown',
            has_push_tokens: false
          }
        end

        def get_package_info(notification)
          return nil unless notification.package_id
          
          package = Package.find_by(id: notification.package_id)
          if package
            {
              id: package.id,
              code: package.code,
              state: package.state
            }
          else
            {
              id: notification.package_id,
              code: 'Deleted Package',
              state: 'deleted'
            }
          end
        rescue
          nil
        end

        def time_ago(time)
          return 'Unknown' unless time
          
          seconds = Time.current - time
          
          case seconds
          when 0..59
            'just now'
          when 60..3599
            "#{(seconds / 60).round}m ago"
          when 3600..86399
            "#{(seconds / 3600).round}h ago"
          else
            "#{(seconds / 86400).round}d ago"
          end
        rescue
          'Unknown'
        end

        def format_date(datetime)
          return 'Unknown date' unless datetime
          
          datetime.strftime('%B %d, %Y at %I:%M %p')
        rescue
          'Unknown date'
        end
      end
    end
  end
end