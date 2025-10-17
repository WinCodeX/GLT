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

          # Apply filters
          @notifications = @notifications.where(read: false) if params[:unread_only] == 'true'
          @notifications = @notifications.where(notification_type: params[:type]) if params[:type].present?
          
          # Apply category filter
          if params[:category].present?
            @notifications = filter_by_category(@notifications, params[:category])
          end

          # Paginate
          total_count = @notifications.count
          @notifications = @notifications.offset(offset).limit(per_page)

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
        
        # Broadcast notification read status
        broadcast_notification_read(@notification)
        
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
          notification_ids = current_user.notifications.where(read: false).pluck(:id)
          
          current_user.notifications.where(read: false).update_all(
            read: true,
            read_at: Time.current
          )

          # Broadcast all notifications read
          broadcast_all_notifications_read(notification_ids)

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

      # POST /api/v1/notifications/mark_visible_as_read
      def mark_visible_as_read
        begin
          notification_ids = params[:notification_ids] || []
          
          if notification_ids.empty?
            render json: {
              success: false,
              message: 'No notification IDs provided'
            }, status: :unprocessable_entity
            return
          end

          # Only mark notifications that belong to current user and are unread
          notifications_to_update = current_user.notifications
                                                .where(id: notification_ids)
                                                .where(read: false)
          
          updated_ids = notifications_to_update.pluck(:id)
          
          notifications_to_update.update_all(
            read: true,
            read_at: Time.current
          )

          # Broadcast each notification as read
          updated_ids.each do |notification_id|
            ActionCable.server.broadcast(
              "user_notifications_#{current_user.id}",
              {
                type: 'notification_read',
                notification_id: notification_id,
                user_id: current_user.id,
                timestamp: Time.current.iso8601
              }
            )
          end

          Rails.logger.info "📖 Marked #{updated_ids.size} visible notifications as read for user #{current_user.id}"

          render json: {
            success: true,
            message: "#{updated_ids.size} notifications marked as read",
            marked_ids: updated_ids
          }, status: :ok
        rescue => e
          Rails.logger.error "NotificationsController#mark_visible_as_read error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to mark visible notifications as read',
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
          Rails.logger.info "Fetching unread notification count for user #{current_user.id}"
          
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

      def filter_by_category(notifications, category)
        case category
        when 'customer_care'
          notifications.where(notification_type: ['support', 'message', 'inquiry', 'complaint'])
        when 'packages'
          notifications.where(notification_type: [
            'package_created', 'package_submitted', 'package_rejected', 
            'package_expired', 'package_delivered', 'package_collected',
            'delivery', 'assignment'
          ])
        when 'updates'
          notifications.where(notification_type: [
            'system', 'announcement', 'update', 'maintenance', 
            'feature', 'promotion'
          ])
        else
          notifications
        end
      end

      def broadcast_notification_read(notification)
        ActionCable.server.broadcast(
          "user_notifications_#{current_user.id}",
          {
            type: 'notification_read',
            notification_id: notification.id,
            user_id: current_user.id,
            timestamp: Time.current.iso8601
          }
        )

        Rails.logger.info "📡 Broadcasted notification_read for notification #{notification.id}"
      end

      def broadcast_all_notifications_read(notification_ids)
        ActionCable.server.broadcast(
          "user_notifications_#{current_user.id}",
          {
            type: 'all_notifications_read',
            notification_ids: notification_ids,
            user_id: current_user.id,
            timestamp: Time.current.iso8601
          }
        )

        Rails.logger.info "📡 Broadcasted all_notifications_read for #{notification_ids.size} notifications"
      end

      def serialize_notification(notification, include_full_details: false)
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