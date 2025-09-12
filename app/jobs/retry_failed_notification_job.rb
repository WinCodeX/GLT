# app/jobs/retry_failed_notification_job.rb
class RetryFailedNotificationJob < ApplicationJob
  queue_as :notifications

  def perform(notification_id)
    notification = Notification.find_by(id: notification_id)
    return unless notification&.status == 'failed' && notification.deliverable?

    Rails.logger.info "Retrying failed notification #{notification_id}"
    
    # Reset status to pending and retry delivery
    notification.update!(status: 'pending')
    DeliverNotificationJob.perform_later(notification)
  end
end