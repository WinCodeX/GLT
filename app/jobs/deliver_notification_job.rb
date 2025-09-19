
# app/jobs/deliver_notification_job.rb
class DeliverNotificationJob < ApplicationJob
  queue_as :notifications
  
  def perform(notification)
    return unless notification.deliverable?
    
    Rails.logger.info "📨 Delivering notification #{notification.id} to user #{notification.user.id}"
    
    begin
      case notification.channel
      when 'push'
        deliver_push_notification(notification)
      when 'email'
        deliver_email_notification(notification)
      when 'sms'
        deliver_sms_notification(notification)
      else
        deliver_in_app_notification(notification)
      end
      
      notification.mark_as_delivered!
      
    rescue => e
      Rails.logger.error "❌ Failed to deliver notification #{notification.id}: #{e.message}"
      notification.mark_as_failed!
      
      # Retry after 5 minutes for failed notifications
      RetryFailedNotificationJob.set(wait: 5.minutes).perform_later(notification.id)
    end
  end
  
  private
  
  def deliver_push_notification(notification)
    Rails.logger.info "📱 Delivering push notification #{notification.id}"
    
    # Use the existing PushNotificationService
    push_service = PushNotificationService.new
    push_service.send_immediate(notification)
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
    rescue => e
      Rails.logger.error "Failed to broadcast notification #{notification.id}: #{e.message}"
      raise e
    end
  end
  
  def deliver_email_notification(notification)
    # Implement email delivery when ready
    # NotificationMailer.notification_email(notification).deliver_now
    Rails.logger.info "📧 Email notification sent for #{notification.id}"
  end
  
  def deliver_sms_notification(notification)
    # Implement SMS delivery when ready (Twilio, etc.)
    Rails.logger.info "📱 SMS notification sent for #{notification.id}"
  end
end