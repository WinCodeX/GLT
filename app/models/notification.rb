# app/models/notification.rb
class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :package, optional: true

  # EXISTING ENUM DEFINITIONS (PRESERVED)
  enum notification_type: {
    package_rejected: 'package_rejected',
    package_expired: 'package_expired', 
    payment_reminder: 'payment_reminder',
    package_delivered: 'package_delivered',
    package_collected: 'package_collected',
    resubmission_available: 'resubmission_available',
    final_warning: 'final_warning',
    general: 'general',
    # NEW: Add package update types for push notifications
    package_ready: 'package_ready',
    package_update: 'package_update',
    payment_failed: 'payment_failed'
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
    urgent: 2,
    # NEW: Add low priority for compatibility
    low: -1
  }

  enum status: {
    pending: 'pending',
    sent: 'sent', 
    failed: 'failed',
    expired: 'expired'
  }

  validates :title, :message, :notification_type, presence: true

  # EXISTING SCOPES (PRESERVED) + NEW ONES
  scope :unread, -> { where(read: false) }
  scope :read, -> { where(read: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }
  scope :by_type, ->(type) { where(notification_type: type) }
  scope :active, -> { where('expires_at IS NULL OR expires_at > ?', Time.current) }
  scope :expired, -> { where('expires_at <= ?', Time.current) }
  scope :deliverable, -> { where(status: ['pending', 'failed']).active }

  # ENHANCED CALLBACKS - PRESERVE EXISTING + ADD PUSH FUNCTIONALITY
  after_create :schedule_delivery
  after_create_commit :broadcast_to_user  # NEW: Real-time broadcast
  after_update :handle_delivery_status_change

  # EXISTING METHODS (PRESERVED)
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

  # FIXED: INSTANT PUSH NOTIFICATION METHOD - Extract control parameters
  def self.create_and_broadcast!(attributes)
    # Extract control parameters that aren't database attributes
    should_send_immediate_push = attributes.delete(:instant_push)
    
    # Create the notification with only valid database attributes
    notification = create!(attributes)
    
    # Send immediate push notification if requested or if channel is push
    if notification.channel == 'push' || should_send_immediate_push
      begin
        PushNotificationService.new.send_immediate(notification)
        Rails.logger.info "📱 Immediate push sent for notification #{notification.id}"
      rescue => e
        Rails.logger.error "❌ Immediate push failed for notification #{notification.id}: #{e.message}"
      end
    end
    
    notification
  end

  # FIXED: ENHANCED NOTIFICATION CREATION WITH PUSH SUPPORT
  def self.create_with_push(attributes)
    # Set default channel to push and mark for immediate sending
    unless attributes.key?(:channel)
      attributes[:channel] = 'push'
    end
    
    # Always send immediate push for this method
    attributes[:instant_push] = true
    
    create_and_broadcast!(attributes)
  end

  # EXISTING BUSINESS LOGIC METHODS (PRESERVED + ENHANCED WITH PUSH)
  def self.create_package_rejection(package:, reason:, auto_rejected: false)
    title = auto_rejected ? "Package #{package.code} Automatically Rejected" : "Package #{package.code} Rejected"
    
    message = if auto_rejected
      "Your package #{package.code} has been automatically rejected due to #{reason}. You can resubmit this package with reduced time limits."
    else
      "Your package #{package.code} has been rejected. Reason: #{reason}. You can resubmit this package if eligible."
    end

    # ENHANCED: Use push notifications for immediate delivery
    create_with_push(
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

  def self.create_expiry_warning(package:, hours_remaining:)
    # ENHANCED: Use push notifications for critical warnings
    create_with_push(
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

  def self.create_resubmission_success(package:, new_deadline:)
    deadline_hours = ((new_deadline - Time.current) / 1.hour).round(1)
    
    # ENHANCED: Use push notifications for positive updates
    create_with_push(
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

  # NEW: ADDITIONAL PACKAGE NOTIFICATION METHODS WITH PUSH
  def self.create_package_delivered(package:)
    create_with_push(
      user: package.user,
      package: package,
      title: "Package Delivered!",
      message: "Your package #{package.code} has been delivered successfully.",
      notification_type: 'package_delivered',
      priority: 'high',
      icon: 'check-circle',
      action_url: "/track/#{package.code}"
    )
  end

  def self.create_package_ready(package:)
    create_with_push(
      user: package.user,
      package: package,
      title: "Package Ready for Pickup",
      message: "Package #{package.code} is ready for collection.",
      notification_type: 'package_ready',
      priority: 'normal',
      icon: 'clock',
      action_url: "/track/#{package.code}"
    )
  end

  def self.create_payment_reminder(package:)
    create_with_push(
      user: package.user,
      package: package,
      title: "Payment Due",
      message: "Package #{package.code} payment is due. Total: $#{package.total_amount}",
      notification_type: 'payment_reminder',
      priority: 'normal',
      icon: 'credit-card',
      action_url: "/packages/#{package.id}/payment"
    )
  end

  def self.create_payment_failed(package:, reason: nil)
    message = reason ? 
      "Payment for package #{package.code} failed: #{reason}. Please update payment method." :
      "Payment for package #{package.code} failed. Please update payment method."
    
    create_with_push(
      user: package.user,
      package: package,
      title: "Payment Failed",
      message: message,
      notification_type: 'payment_failed',
      priority: 'high',
      icon: 'x-circle',
      action_url: "/packages/#{package.id}/payment"
    )
  end

  # NEW: GENERAL NOTIFICATION METHODS
  def self.create_broadcast_notification(title, message, user_scope = User.all, options = {})
    notifications_created = 0
    
    user_scope.find_each do |user|
      create_with_push({
        user: user,
        title: title,
        message: message,
        notification_type: options[:type] || 'general',
        priority: options[:priority] || 'normal',
        icon: options[:icon] || 'bell',
        action_url: options[:action_url],
        expires_at: options[:expires_at]
      })
      
      notifications_created += 1
    end
    
    Rails.logger.info "Broadcast sent to #{notifications_created} users"
    notifications_created
  end

  def self.create_user_notification(user, title, message, options = {})
    create_with_push({
      user: user,
      title: title,
      message: message,
      notification_type: options[:type] || 'general',
      priority: options[:priority] || 'normal',
      icon: options[:icon] || 'bell',
      action_url: options[:action_url],
      expires_at: options[:expires_at]
    })
  end

  private

  # EXISTING CALLBACK METHODS (PRESERVED)
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

  # NEW: REAL-TIME BROADCAST METHOD
  def broadcast_to_user
    # Real-time update via ActionCable
    ActionCable.server.broadcast(
      "user_notifications_#{user.id}",
      {
        type: 'new_notification',
        notification: {
          id: id,
          title: title,
          message: message,
          notification_type: notification_type,
          priority: priority,
          read: read,
          created_at: created_at.iso8601,
          icon: icon || 'bell',
          package_code: package_code
        },
        unread_count: user.notifications.unread.count
      }
    )
  end
end