# app/controllers/api/v1/notifications_controller.rb - Fixed with robust error handling
module Api
  module V1
    class NotificationsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_notification, only: [:show, :mark_as_read, :destroy]

      # GET /api/v1/notifications
      def index
        begin
          @notifications = current_user.notifications
                                      .includes(:package)
                                      .order(created_at: :desc)
                                      .page(params[:page] || 1)
                                      .per(params[:per_page] || 20)

          # Apply filters safely
          @notifications = @notifications.where(read: false) if params[:unread_only] == 'true'
          @notifications = @notifications.where(notification_type: params[:type]) if params[:type].present?

          # Calculate unread count safely
          unread_count = current_user.notifications.where(read: false).count

          render json: {
            success: true,
            data: @notifications.map { |notification| serialize_notification(notification) },
            pagination: {
              current_page: @notifications.current_page,
              total_pages: @notifications.total_pages,
              total_count: @notifications.total_count,
              per_page: @notifications.limit_value
            },
            unread_count: unread_count
          }
        rescue => e
          Rails.logger.error "NotificationsController#index error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          render json: {
            success: false,
            message: 'Failed to fetch notifications',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
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
        @notification.update!(read: true, read_at: Time.current)
        
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
        begin
          count = current_user.notifications.where(read: false).count
          current_user.notifications.where(read: false).update_all(
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

      # GET /api/v1/notifications/unread_count - FIXED: Robust implementation
      def unread_count
        begin
          Rails.logger.info "Fetching unread notification count for user #{current_user.id}"
          
          # Simple, safe query without assuming scopes exist
          count = current_user.notifications.where(read: false).count
          
          Rails.logger.info "Found #{count} unread notifications"
          
          render json: {
            success: true,
            unread_count: count
          }
        rescue => e
          Rails.logger.error "NotificationsController#unread_count error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          render json: {
            success: false,
            message: 'Failed to get unread count',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/notifications/summary
      def summary
        begin
          notifications = current_user.notifications
                                     .order(created_at: :desc)
                                     .limit(5)
          
          unread_count = current_user.notifications.where(read: false).count
          total_count = current_user.notifications.count
          
          render json: {
            success: true,
            data: {
              recent_notifications: notifications.map { |n| serialize_notification(n) },
              unread_count: unread_count,
              total_count: total_count
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
        # Calculate time since creation safely
        time_since_creation = begin
          if notification.created_at
            time_ago_in_words(notification.created_at)
          else
            'Unknown'
          end
        rescue
          'Unknown'
        end

        # Format created_at safely
        formatted_created_at = begin
          if notification.created_at
            notification.created_at.strftime('%B %d, %Y at %I:%M %p')
          else
            'Unknown date'
          end
        rescue
          'Unknown date'
        end

        result = {
          id: notification.id,
          title: notification.title || 'Notification',
          message: notification.message || '',
          notification_type: notification.notification_type || 'general',
          priority: notification.priority || 'normal',
          read: notification.read || false,
          delivered: notification.delivered || false,
          created_at: notification.created_at&.iso8601,
          time_since_creation: time_since_creation,
          formatted_created_at: formatted_created_at,
          icon: notification.icon || 'bell',
          action_url: notification.action_url,
          expires_at: notification.expires_at&.iso8601,
          expired: notification.expires_at ? notification.expires_at <= Time.current : false
        }

        # Include package information if available
        if notification.package
          result[:package] = {
            id: notification.package.id,
            code: notification.package.code,
            state: notification.package.state,
            state_display: notification.package.state.humanize
          }
        elsif notification.package_id && notification.metadata.is_a?(Hash) && notification.metadata['package_code']
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
            metadata: notification.metadata || {},
            read_at: notification.read_at&.iso8601,
            delivered_at: notification.delivered_at&.iso8601,
            status: notification.status || 'pending',
            channel: notification.channel || 'in_app'
          )
        end

        result
      end

      # Helper method to safely use time_ago_in_words
      def time_ago_in_words(time)
        # Simple implementation that doesn't rely on ActionView helpers
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
      end
    end
  end
end