# app/controllers/api/v1/notifications_controller.rb - Fixed with forced JSON responses
module Api
  module V1
    class NotificationsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_notification, only: [:show, :mark_as_read, :destroy]
      
      # Force JSON responses for all actions
      respond_to :json

      # GET /api/v1/notifications
      def index
        begin
          # Fixed pagination - use offset/limit instead of kaminari to avoid dependency issues
          page = [params[:page].to_i, 1].max
          per_page = [params[:per_page].to_i, 20].max.clamp(1, 100)
          offset = (page - 1) * per_page

          @notifications = current_user.notifications
                                      .includes(:package)
                                      .order(created_at: :desc)
                                      .offset(offset)
                                      .limit(per_page)

          # Apply filters safely
          @notifications = @notifications.where(read: false) if params[:unread_only] == 'true'
          @notifications = @notifications.where(notification_type: params[:type]) if params[:type].present?

          # Get total count for pagination
          total_count = current_user.notifications.count
          total_pages = (total_count.to_f / per_page).ceil

          # Calculate unread count safely
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
          Rails.logger.error e.backtrace.join("\n")
          
          render json: {
            success: false,
            message: 'Failed to fetch notifications',
            error: Rails.env.development? ? e.message : 'Internal server error'
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/notifications/:id
      def show
        render json: {
          success: true,
          data: serialize_notification(@notification, include_full_details: true)
        }, status: :ok
      rescue => e
        Rails.logger.error "NotificationsController#show error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to fetch notification',
          error: Rails.env.development? ? e.message : 'Internal server error'
        }, status: :internal_server_error
      end

      # PATCH /api/v1/notifications/:id/mark_as_read
      def mark_as_read
        @notification.update!(read: true, read_at: Time.current)
        
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
          }, status: :ok
        rescue => e
          Rails.logger.error "NotificationsController#mark_all_as_read error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to mark all notifications as read',
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

      # GET /api/v1/notifications/unread_count - FIXED: Simplified implementation
      def unread_count
        begin
          Rails.logger.info "Fetching unread notification count for user #{current_user.id}"
          
          # Simple, direct query
          count = current_user.notifications.where(read: false).count
          
          Rails.logger.info "Found #{count} unread notifications"
          
          render json: {
            success: true,
            unread_count: count
          }, status: :ok
        rescue => e
          Rails.logger.error "NotificationsController#unread_count error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          render json: {
            success: false,
            message: 'Failed to get unread count',
            error: Rails.env.development? ? e.message : 'Internal server error'
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
          }, status: :ok
        rescue => e
          Rails.logger.error "NotificationsController#summary error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to get notifications summary',
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

      # Simplified serialization to prevent errors
      def serialize_notification(notification, include_full_details: false)
        # Safe attribute access with fallbacks
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

        # Add time calculations safely
        if notification.created_at
          result[:time_since_creation] = time_ago_in_words(notification.created_at)
          result[:formatted_created_at] = notification.created_at.strftime('%B %d, %Y at %I:%M %p')
        else
          result[:time_since_creation] = 'Unknown'
          result[:formatted_created_at] = 'Unknown date'
        end

        # Add expiration status
        result[:expired] = notification.expires_at ? notification.expires_at <= Time.current : false

        # Include package information safely
        if notification.package
          result[:package] = {
            id: notification.package.id,
            code: notification.package.code,
            state: notification.package.state,
            state_display: notification.package.state.humanize
          }
        elsif notification.package_id && notification.metadata.is_a?(Hash)
          package_code = notification.metadata['package_code'] || notification.metadata[:package_code]
          if package_code
            result[:package] = {
              code: package_code,
              state: 'deleted',
              state_display: 'Deleted'
            }
          end
        end

        # Include full details if requested
        if include_full_details
          result.merge!(
            metadata: notification.metadata || {},
            read_at: notification.read_at&.iso8601,
            delivered_at: notification.delivered_at&.iso8601,
            status: notification.status.presence || 'pending',
            channel: notification.channel.presence || 'in_app'
          )
        end

        result
      rescue => e
        Rails.logger.error "Error serializing notification #{notification.id}: #{e.message}"
        # Return minimal safe data if serialization fails
        {
          id: notification.id,
          title: 'Notification',
          message: 'Error loading notification details',
          notification_type: 'error',
          read: false,
          created_at: notification.created_at&.iso8601
        }
      end

      # Simple time ago calculation
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