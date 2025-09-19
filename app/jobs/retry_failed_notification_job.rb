
# app/jobs/retry_failed_notification_job.rb
class RetryFailedNotificationJob < ApplicationJob
  queue_as :notifications
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(notification_id)
    notification = Notification.find_by(id: notification_id)
    return unless notification&.status == 'failed' && notification.deliverable?

    Rails.logger.info "Retrying failed notification #{notification_id}"
    
    # Reset status to pending
    notification.update!(status: 'pending')
    
    # Attempt redelivery
    DeliverNotificationJob.perform_later(notification)
  end
end