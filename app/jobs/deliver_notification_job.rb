# app/jobs/deliver_notification_job.rb
class DeliverNotificationJob < ApplicationJob
  queue_as :notifications
  
  def perform(notification)
    Rails.logger.info "🚀 DeliverNotificationJob started for notification #{notification.id}"
    Rails.logger.info "📋 Notification details: user_id=#{notification.user_id}, channel=#{notification.channel}, type=#{notification.notification_type}"
    
    # Check if notification responds to deliverable method
    if notification.respond_to?(:deliverable?)
      deliverable = notification.deliverable?
      Rails.logger.info "📦 Notification deliverable check: #{deliverable}"
      return unless deliverable
    else
      Rails.logger.warn "⚠️ Notification doesn't respond to deliverable? method - proceeding anyway"
    end
    
    Rails.logger.info "📨 Delivering notification #{notification.id} to user #{notification.user.id}"
    
    begin
      case notification.channel
      when 'push'
        Rails.logger.info "📱 Attempting push notification delivery"
        deliver_push_notification(notification)
      when 'email'
        Rails.logger.info "📧 Attempting email notification delivery"
        deliver_email_notification(notification)
      when 'sms'
        Rails.logger.info "📲 Attempting SMS notification delivery"
        deliver_sms_notification(notification)
      else
        Rails.logger.info "📢 Attempting in-app notification delivery"
        deliver_in_app_notification(notification)
      end
      
      # Check if mark_as_delivered! method exists
      if notification.respond_to?(:mark_as_delivered!)
        Rails.logger.info "✅ Marking notification #{notification.id} as delivered"
        notification.mark_as_delivered!
      else
        Rails.logger.warn "⚠️ Notification doesn't respond to mark_as_delivered! method"
        # Fallback - try to update status directly
        if notification.respond_to?(:status=)
          notification.update!(status: 'delivered', delivered_at: Time.current)
          Rails.logger.info "✅ Updated notification status via fallback method"
        end
      end
      
      Rails.logger.info "🎉 Successfully processed notification #{notification.id}"
      
    rescue => e
      Rails.logger.error "❌ Failed to deliver notification #{notification.id}: #{e.message}"
      Rails.logger.error "🔍 Error class: #{e.class.name}"
      Rails.logger.error "🔍 Error backtrace: #{e.backtrace.first(5).join(', ')}"
      
      # Check if mark_as_failed! method exists
      if notification.respond_to?(:mark_as_failed!)
        notification.mark_as_failed!
      else
        Rails.logger.warn "⚠️ Notification doesn't respond to mark_as_failed! method"
        # Fallback
        if notification.respond_to?(:status=)
          notification.update!(status: 'failed')
        end
      end
      
      # Retry after 5 minutes for failed notifications
      if defined?(RetryFailedNotificationJob)
        RetryFailedNotificationJob.set(wait: 5.minutes).perform_later(notification.id)
      else
        Rails.logger.warn "⚠️ RetryFailedNotificationJob not defined - skipping retry"
      end
    end
  end
  
  private
  
  def deliver_push_notification(notification)
    Rails.logger.info "📱 Starting push notification delivery for notification #{notification.id}"
    
    # Check if user has push tokens
    user = notification.user
    Rails.logger.info "👤 User: #{user.id} (#{user.email})"
    
    if user.respond_to?(:push_tokens)
      active_tokens = user.push_tokens.active rescue []
      Rails.logger.info "🔑 User has #{active_tokens.count} active push tokens"
      
      if active_tokens.empty?
        Rails.logger.warn "⚠️ No active push tokens found for user #{user.id}"
        return
      end
    else
      Rails.logger.error "❌ User model doesn't respond to push_tokens method"
      return
    end
    
    # Use the existing PushNotificationService
    Rails.logger.info "🚀 Calling PushNotificationService.send_immediate"
    push_service = PushNotificationService.new
    push_service.send_immediate(notification)
    Rails.logger.info "✅ PushNotificationService.send_immediate completed"
  end
  
  def deliver_in_app_notification(notification)
    # In-app notifications are handled by ActionCable broadcasting
    Rails.logger.info "📲 Broadcasting in-app notification #{notification.id} to user #{notification.user.id}"
    
    # Broadcast to user's notification channel
    begin
      ActionCable.server.broadcast(
        "user_notifications_#{notification.user.id}",
        {
          type: 'new_notification',
          notification: notification.as_json(include: [:package])
        }
      )
      Rails.logger.info "✅ Successfully broadcasted in-app notification"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast notification #{notification.id}: #{e.message}"
      raise e
    end
  end
  
  def deliver_email_notification(notification)
    # Implement email delivery when ready
    # NotificationMailer.notification_email(notification).deliver_now
    Rails.logger.info "📧 Email notification sent for #{notification.id} (placeholder)"
  end
  
  def deliver_sms_notification(notification)
    # Implement SMS delivery when ready (Twilio, etc.)
    Rails.logger.info "📱 SMS notification sent for #{notification.id} (placeholder)"
  end
end