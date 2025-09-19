
# app/services/notification_creator_service.rb
class NotificationCreatorService
  def self.create_package_notification(package, type, additional_data = {})
    notification_data = {
      user: package.user,
      package: package,
      notification_type: type,
      channel: 'push', # Always send as push for instant delivery
      priority: determine_priority(type),
      **build_notification_content(package, type, additional_data)
    }
    
    # Create notification and immediately deliver via push
    notification = Notification.create!(notification_data)
    
    # Immediately send push notification
    DeliverNotificationJob.perform_later(notification)
    
    notification
  end
  
  def self.create_broadcast_notification(title, message, user_scope = User.all, options = {})
    notifications_created = 0
    
    user_scope.find_each do |user|
      notification = Notification.create!({
        user: user,
        title: title,
        message: message,
        notification_type: options[:type] || 'general',
        channel: 'push',
        priority: options[:priority] || 'normal',
        icon: options[:icon] || 'bell',
        action_url: options[:action_url],
        expires_at: options[:expires_at]
      })
      
      # Immediately send push notification
      DeliverNotificationJob.perform_later(notification)
      
      notifications_created += 1
    end
    
    Rails.logger.info "Broadcast sent to #{notifications_created} users"
    notifications_created
  end
  
  def self.create_user_notification(user, title, message, options = {})
    notification = Notification.create!({
      user: user,
      title: title,
      message: message,
      notification_type: options[:type] || 'general',
      channel: 'push',
      priority: options[:priority] || 'normal',
      icon: options[:icon] || 'bell',
      action_url: options[:action_url],
      expires_at: options[:expires_at]
    })
    
    # Immediately send push notification
    DeliverNotificationJob.perform_later(notification)
    
    notification
  end
  
  private
  
  def self.determine_priority(type)
    case type
    when 'package_delivered', 'payment_failed', 'package_rejected', 'expiry_warning'
      'high'
    when 'package_ready', 'payment_reminder', 'package_update'
      'normal'
    else
      'low'
    end
  end
  
  def self.build_notification_content(package, type, additional_data)
    base_content = case type
    when 'package_delivered'
      {
        title: 'Package Delivered!',
        message: "Your package #{package.code} has been delivered successfully.",
        icon: 'check-circle'
      }
    when 'package_ready'
      {
        title: 'Package Ready for Pickup',
        message: "Package #{package.code} is ready for collection.",
        icon: 'clock'
      }
    when 'payment_reminder'
      {
        title: 'Payment Due',
        message: "Package #{package.code} payment is due. Total: KES #{package.cost}",
        icon: 'credit-card',
        action_url: "/packages/#{package.id}/payment"
      }
    when 'expiry_warning'
      {
        title: 'Package Expiring Soon',
        message: "Package #{package.code} storage period will expire soon.",
        icon: 'alert-triangle'
      }
    when 'package_rejected'
      {
        title: 'Package Rejected',
        message: "Package #{package.code} has been rejected.",
        icon: 'x-circle'
      }
    when 'package_deleted'
      {
        title: 'Package Deleted',
        message: "Package #{package.code} has been permanently deleted.",
        icon: 'trash-2'
      }
    when 'payment_failed'
      {
        title: 'Payment Failed',
        message: "Payment for package #{package.code} failed. Please update payment method.",
        icon: 'x-circle',
        action_url: "/packages/#{package.id}/payment"
      }
    else
      {
        title: 'Package Update',
        message: "Your package #{package.code} has been updated.",
        icon: 'package'
      }
    end
    
    # Merge with additional data, allowing overrides
    base_content.merge(additional_data)
  end
end