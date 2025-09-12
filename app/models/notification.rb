# app/models/notification.rb
class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :package, optional: true

  enum notification_type: {
    package_rejected: 'package_rejected',
    package_expired: 'package_expired', 
    payment_reminder: 'payment_reminder',
    package_delivered: 'package_delivered',
    package_collected: 'package_collected',
    resubmission_available: 'resubmission_available',
    final_warning: 'final_warning',
    general: 'general'
  }

  enum channel: {
    in_app: 'in_app',
    email: 'email', 
    sms: 'sms',
    push: 'push'
  }

  enum priority: {
    normal: 0,
    high: 1,
    urgent: 2
  }

  enum status: {
    pending: 'pending',
    sent: 'sent', 
    failed: 'failed',
    expired: 'expired'
  }

  validates :title, :message, :notification_type, presence: true

  scope :unread, -> { where(read: false) }
  scope :read, -> { where(read: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }
  scope :by_type, ->(type) { where(notification_type: type) }
  scope :active, -> { where('expires_at IS NULL OR expires_at > ?', Time.current) }
  scope :expired, -> { where('expires_at <= ?', Time.current) }
  scope :deliverable, -> { where(status: ['pending', 'failed']).active }

  after_create :schedule_delivery
  after_update :handle_delivery_status_change

  def mark_as_read!
    return if read?
    
    update!(
      read: true,
      read_at: Time.current
    )
  end

  def mark_as_delivered!
    return if delivered?
    
    update!(
      delivered: true,
      delivered_at: Time.current,
      status: 'sent'
    )
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def deliverable?
    !expired? && status.in?(['pending', 'failed'])
  end

  def package_code
    package&.code
  end

  def formatted_created_at
    created_at.strftime('%B %d, %Y at %I:%M %p')
  end

  def time_since_creation
    distance_of_time = Time.current - created_at
    
    if distance_of_time < 1.minute
      'Just now'
    elsif distance_of_time < 1.hour
      "#{(distance_of_time / 1.minute).to_i}m ago"
    elsif distance_of_time < 1.day
      "#{(distance_of_time / 1.hour).to_i}h ago"
    elsif distance_of_time < 1.week
      "#{(distance_of_time / 1.day).to_i}d ago"
    else
      created_at.strftime('%b %d, %Y')
    end
  end

  # Create notification for package rejection
  def self.create_package_rejection(package:, reason:, auto_rejected: false)
    title = auto_rejected ? "Package #{package.code} Automatically Rejected" : "Package #{package.code} Rejected"
    
    message = if auto_rejected
      "Your package #{package.code} has been automatically rejected due to #{reason}. You can resubmit this package with reduced time limits."
    else
      "Your package #{package.code} has been rejected. Reason: #{reason}. You can resubmit this package if eligible."
    end

    create!(
      user: package.user,
      package: package,
      title: title,
      message: message,
      notification_type: 'package_rejected',
      priority: 'high',
      metadata: {
        rejection_reason: reason,
        auto_rejected: auto_rejected,
        resubmission_count: package.resubmission_count,
        can_resubmit: package.can_be_resubmitted?
      },
      icon: 'x-circle',
      action_url: "/track/#{package.code}"
    )
  end

  # Create notification for package expiry warning
  def self.create_expiry_warning(package:, hours_remaining:)
    create!(
      user: package.user,
      package: package,
      title: "Package #{package.code} Expires Soon",
      message: "Your package #{package.code} will be automatically rejected in #{hours_remaining} hours if no action is taken.",
      notification_type: 'final_warning',
      priority: 'urgent',
      metadata: {
        hours_remaining: hours_remaining,
        expiry_deadline: package.expiry_deadline
      },
      icon: 'clock',
      action_url: "/track/#{package.code}"
    )
  end

  # Create notification for successful resubmission
  def self.create_resubmission_success(package:, new_deadline:)
    deadline_hours = ((new_deadline - Time.current) / 1.hour).round(1)
    
    create!(
      user: package.user,
      package: package,
      title: "Package #{package.code} Resubmitted Successfully",
      message: "Your package has been resubmitted and restored to #{package.original_state || 'pending'} status. New deadline: #{deadline_hours} hours from now.",
      notification_type: 'resubmission_available',
      priority: 'normal',
      metadata: {
        new_deadline: new_deadline,
        resubmission_count: package.resubmission_count,
        remaining_resubmissions: 2 - package.resubmission_count
      },
      icon: 'check-circle',
      action_url: "/track/#{package.code}"
    )
  end

  private

  def schedule_delivery
    # Schedule background job to deliver the notification
    DeliverNotificationJob.perform_later(self) if deliverable?
  end

  def handle_delivery_status_change
    if saved_change_to_status? && status == 'failed'
      # Retry failed notifications after some time
      RetryFailedNotificationJob.perform_in(30.minutes, self.id)
    end
  end
end