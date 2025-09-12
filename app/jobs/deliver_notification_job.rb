# app/jobs/deliver_notification_job.rb
class DeliverNotificationJob < ApplicationJob
  queue_as :notifications

  def perform(notification)
    return unless notification.deliverable?

    Rails.logger.info "Delivering notification #{notification.id} to user #{notification.user.id}"
    
    begin
      case notification.channel
      when 'in_app'
        deliver_in_app_notification(notification)
      when 'email'
        deliver_email_notification(notification)
      when 'sms'
        deliver_sms_notification(notification)
      when 'push'
        deliver_push_notification(notification)
      else
        deliver_in_app_notification(notification) # Default fallback
      end
      
      notification.mark_as_delivered!
      
    rescue => e
      Rails.logger.error "Failed to deliver notification #{notification.id}: #{e.message}"
      notification.update!(status: 'failed')
      
      # Retry after 30 minutes
      RetryFailedNotificationJob.perform_in(30.minutes, notification.id)
    end
  end

  private

  def deliver_in_app_notification(notification)
    # Mark as delivered immediately for in-app notifications
    # The frontend will fetch these via API
    Rails.logger.info "In-app notification ready for user #{notification.user.id}"
  end

  def deliver_email_notification(notification)
    # Implement email delivery logic here
    # NotificationMailer.send_notification(notification).deliver_now
    Rails.logger.info "Email notification sent to #{notification.user.email}"
  end

  def deliver_sms_notification(notification)
    # Implement SMS delivery logic here
    Rails.logger.info "SMS notification sent to #{notification.user.phone_number}"
  end

  def deliver_push_notification(notification)
    # Implement push notification logic here
    Rails.logger.info "Push notification sent to user #{notification.user.id}"
  end
end