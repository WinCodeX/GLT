# app/controllers/api/v1/notifications_controller.rb
module Api
  module V1
    class NotificationsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_notification, only: [:show, :mark_as_read, :destroy]
      
      respond_to :json

      # GET /api/v1/notifications
      def index
        begin
          page = [params[:page].to_i, 1].max
          per_page = [params[:per_page].to_i, 20].max.clamp(1, 100)
          offset = (page - 1) * per_page

          @notifications = current_user.notifications
                                      .includes(:package)
                                      .order(created_at: :desc)
                                      .offset(offset)
                                      .limit(per_page)

          # Apply category filter
          if params[:category].present? && params[:category] != 'all'
            @notifications = filter_by_category(@notifications, params[:category])
          end

          # Apply unread filter
          @notifications = @notifications.where(read: false) if params[:unread_only] == 'true'

          total_count = current_user.notifications.count
          total_pages = (total_count.to_f / per_page).ceil
          unread_count = current_user.notifications.where(read: false).count

          render json: {
            success: true,
            data: @notifications.map { |notification| serialize_notification(notification) },
            pagination: {
              current_page: page,
              total_pages: total_pages,
              total_count: total_count,
              per_page: per_page
            },
            unread_count: unread_count
          }, status: :ok
        rescue => e
          Rails.logger.error "NotificationsController#index error: #{e.message}"
          
          render json: {
            success: false,
            message: 'Failed to fetch notifications',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end
      end

      # PATCH /api/v1/notifications/:id/mark_as_read
      def mark_as_read
        @notification.update!(read: true, read_at: Time.current)
        
        # Broadcast to user channel
        ActionCable.server.broadcast(
          "user_notifications_#{current_user.id}",
          {
            type: 'notification_read',
            notification_id: @notification.id,
            timestamp: Time.current.iso8601
          }
        )
        
        render json: {
          success: true,
          message: 'Notification marked as read',
          data: serialize_notification(@notification)
        }, status: :ok
      rescue => e
        Rails.logger.error "NotificationsController#mark_as_read error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to mark notification as read',
          error: Rails.env.development? ? e.message : 'Internal server error'
        }, status: :internal_server_error
      end

      # PATCH /api/v1/notifications/mark_multiple_as_read
      def mark_multiple_as_read
        begin
          notification_ids = params[:notification_ids] || []
          
          if notification_ids.empty?
            return render json: {
              success: false,
              message: 'No notification IDs provided'
            }, status: :unprocessable_entity
          end

          notifications = current_user.notifications.where(id: notification_ids, read: false)
          count = notifications.count
          
          notifications.update_all(
            read: true,
            read_at: Time.current
          )

          # Broadcast each notification as read
          notification_ids.each do |notification_id|
            ActionCable.server.broadcast(
              "user_notifications_#{current_user.id}",
              {
                type: 'notification_read',
                notification_id: notification_id,
                timestamp: Time.current.iso8601
              }
            )
          end

          render json: {
            success: true,
            message: "#{count} notifications marked as read",
            count: count
          }, status: :ok
        rescue => e
          Rails.logger.error "NotificationsController#mark_multiple_as_read error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to mark notifications as read',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end
      end

      # DELETE /api/v1/notifications/:id
      def destroy
        @notification.destroy!
        
        render json: {
          success: true,
          message: 'Notification deleted'
        }, status: :ok
      rescue => e
        Rails.logger.error "NotificationsController#destroy error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to delete notification',
          error: Rails.env.development? ? e.message : 'Internal server error'
        }, status: :internal_server_error
      end

      # GET /api/v1/notifications/unread_count
      def unread_count
        begin
          count = current_user.notifications.where(read: false).count
          
          render json: {
            success: true,
            unread_count: count
          }, status: :ok
        rescue => e
          Rails.logger.error "NotificationsController#unread_count error: #{e.message}"
          
          render json: {
            success: false,
            message: 'Failed to get unread count',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end
      end

      private

      def set_notification
        @notification = current_user.notifications.find_by!(id: params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: {
          success: false,
          message: 'Notification not found'
        }, status: :not_found
      end

      def filter_by_category(notifications, category)
        case category.downcase
        when 'customer_care'
          notifications.where(notification_type: ['support', 'message', 'conversation', 'system'])
        when 'packages'
          notifications.where("notification_type LIKE ? OR notification_type IN (?)", 
                            'package_%', ['delivery', 'assignment'])
        when 'updates'
          notifications.where(notification_type: ['alert', 'payment_received', 'payment_reminder', 
                                                 'final_warning', 'resubmission_available'])
        else
          notifications
        end
      end

      def serialize_notification(notification)
        result = {
          id: notification.id,
          title: notification.title.presence || 'Notification',
          message: notification.message.presence || '',
          notification_type: notification.notification_type.presence || 'general',
          priority: notification.priority.presence || 'normal',
          read: !!notification.read,
          delivered: !!notification.delivered,
          created_at: notification.created_at&.iso8601,
          icon: notification.icon.presence || 'bell',
          action_url: notification.action_url,
          expires_at: notification.expires_at&.iso8601
        }

        if notification.created_at
          result[:time_since_creation] = time_ago_in_words(notification.created_at)
          result[:formatted_created_at] = notification.created_at.strftime('%B %d, %Y at %I:%M %p')
        else
          result[:time_since_creation] = 'Unknown'
          result[:formatted_created_at] = 'Unknown date'
        end

        result[:expired] = notification.expires_at ? notification.expires_at <= Time.current : false

        if notification.package
          result[:package] = {
            id: notification.package.id,
            code: notification.package.code,
            state: notification.package.state,
            state_display: notification.package.state.humanize
          }
        end

        result
      rescue => e
        Rails.logger.error "Error serializing notification #{notification.id}: #{e.message}"
        {
          id: notification.id,
          title: 'Notification',
          message: 'Error loading notification details',
          notification_type: 'error',
          read: false,
          created_at: notification.created_at&.iso8601
        }
      end

      def time_ago_in_words(time)
        return 'just now' unless time
        
        seconds = Time.current - time
        
        case seconds
        when 0..59
          'just now'
        when 60..3599
          "#{(seconds / 60).round} minutes ago"
        when 3600..86399
          "#{(seconds / 3600).round} hours ago"
        else
          "#{(seconds / 86400).round} days ago"
        end
      rescue
        'Unknown'
      end
    end
  end
end