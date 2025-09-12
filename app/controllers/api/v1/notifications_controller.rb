# app/controllers/api/v1/notifications_controller.rb
module Api
  module V1
    class NotificationsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_notification, only: [:show, :mark_as_read, :destroy]

      # GET /api/v1/notifications
      def index
        @notifications = current_user.notifications
                                   .includes(:package)
                                   .active
                                   .recent
                                   .page(params[:page] || 1)
                                   .per(params[:per_page] || 20)

        # Apply filters
        @notifications = @notifications.where(read: false) if params[:unread_only] == 'true'
        @notifications = @notifications.by_type(params[:type]) if params[:type].present?

        render json: {
          success: true,
          data: @notifications.map { |notification| serialize_notification(notification) },
          pagination: {
            current_page: @notifications.current_page,
            total_pages: @notifications.total_pages,
            total_count: @notifications.total_count,
            per_page: @notifications.limit_value
          },
          unread_count: current_user.notifications.unread.active.count
        }
      rescue => e
        Rails.logger.error "NotificationsController#index error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to fetch notifications',
          error: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
      end

      # GET /api/v1/notifications/:id
      def show
        render json: {
          success: true,
          data: serialize_notification(@notification, include_full_details: true)
        }
      rescue => e
        Rails.logger.error "NotificationsController#show error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to fetch notification',
          error: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
      end

      # PATCH /api/v1/notifications/:id/mark_as_read
      def mark_as_read
        @notification.mark_as_read!
        
        render json: {
          success: true,
          message: 'Notification marked as read',
          data: serialize_notification(@notification)
        }
      rescue => e
        Rails.logger.error "NotificationsController#mark_as_read error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to mark notification as read',
          error: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
      end

      # PATCH /api/v1/notifications/mark_all_as_read
      def mark_all_as_read
        count = current_user.notifications.unread.active.count
        current_user.notifications.unread.active.update_all(
          read: true,
          read_at: Time.current
        )

        render json: {
          success: true,
          message: "#{count} notifications marked as read"
        }
      rescue => e
        Rails.logger.error "NotificationsController#mark_all_as_read error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to mark all notifications as read',
          error: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
      end

      # DELETE /api/v1/notifications/:id
      def destroy
        @notification.destroy!
        
        render json: {
          success: true,
          message: 'Notification deleted'
        }
      rescue => e
        Rails.logger.error "NotificationsController#destroy error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to delete notification',
          error: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
      end

      # GET /api/v1/notifications/unread_count
      def unread_count
        count = current_user.notifications.unread.active.count
        
        render json: {
          success: true,
          unread_count: count
        }
      rescue => e
        Rails.logger.error "NotificationsController#unread_count error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to get unread count',
          error: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
      end

      # GET /api/v1/notifications/summary
      def summary
        notifications = current_user.notifications.active.recent.limit(5)
        
        render json: {
          success: true,
          data: {
            recent_notifications: notifications.map { |n| serialize_notification(n) },
            unread_count: current_user.notifications.unread.active.count,
            total_count: current_user.notifications.active.count
          }
        }
      rescue => e
        Rails.logger.error "NotificationsController#summary error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to get notifications summary',
          error: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
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

      def serialize_notification(notification, include_full_details: false)
        result = {
          id: notification.id,
          title: notification.title,
          message: notification.message,
          notification_type: notification.notification_type,
          priority: notification.priority,
          read: notification.read?,
          delivered: notification.delivered?,
          created_at: notification.created_at.iso8601,
          time_since_creation: notification.time_since_creation,
          formatted_created_at: notification.formatted_created_at,
          icon: notification.icon,
          action_url: notification.action_url,
          expires_at: notification.expires_at&.iso8601,
          expired: notification.expired?
        }

        # Include package information if available
        if notification.package
          result[:package] = {
            id: notification.package.id,
            code: notification.package.code,
            state: notification.package.state,
            state_display: notification.package.state.humanize
          }
        elsif notification.package_id && notification.metadata['package_code']
          # For deleted packages, use metadata
          result[:package] = {
            code: notification.metadata['package_code'],
            state: 'deleted',
            state_display: 'Deleted'
          }
        end

        # Include full details if requested
        if include_full_details
          result.merge!(
            metadata: notification.metadata,
            read_at: notification.read_at&.iso8601,
            delivered_at: notification.delivered_at&.iso8601,
            status: notification.status,
            channel: notification.channel
          )
        end

        result
      end
    end
  end
end