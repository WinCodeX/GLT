# app/services/notification_creator_service.rb - Enhanced with support chat notifications
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
  
  # NEW: Create support message notifications
  def self.create_support_message_notification(message, conversation, recipient_user)
    # Don't notify the sender of their own message
    return if message.user == recipient_user
    
    # Don't notify for system messages
    return if message.is_system?
    
    notification_data = {
      user: recipient_user,
      notification_type: 'support_message',
      channel: 'push',
      priority: determine_support_priority(conversation),
      **build_support_message_content(message, conversation, recipient_user)
    }
    
    # Add conversation metadata
    notification_data[:metadata] = {
      conversation_id: conversation.id,
      message_id: message.id,
      ticket_id: conversation.ticket_id,
      from_user_id: message.user.id,
      from_user_name: message.user.display_name
    }
    
    # Create notification and immediately deliver via push
    notification = Notification.create!(notification_data)
    
    # Immediately send push notification
    DeliverNotificationJob.perform_later(notification)
    
    Rails.logger.info "Created support message notification for user #{recipient_user.id} from conversation #{conversation.id}"
    
    notification
  end
  
  # NEW: Notify all conversation participants about a new message
  def self.notify_conversation_participants(message, conversation)
    return if message.is_system? # Don't notify for system messages
    
    # Get all participants except the message sender
    participants_to_notify = conversation.conversation_participants
                                       .includes(:user)
                                       .where.not(user: message.user)
                                       .map(&:user)
    
    # Create notifications for each participant
    notifications_created = 0
    participants_to_notify.each do |participant|
      begin
        create_support_message_notification(message, conversation, participant)
        notifications_created += 1
      rescue => e
        Rails.logger.error "Failed to create notification for user #{participant.id}: #{e.message}"
      end
    end
    
    Rails.logger.info "Created #{notifications_created} support message notifications for conversation #{conversation.id}"
    notifications_created
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
  
  # NEW: Determine priority for support messages
  def self.determine_support_priority(conversation)
    case conversation.priority.to_s
    when 'urgent'
      'high'
    when 'high'
      'normal'
    else
      'normal'
    end
  end
  
  # NEW: Build notification content for support messages
  def self.build_support_message_content(message, conversation, recipient_user)
    sender_name = message.user.display_name
    is_customer = !message.from_support?
    is_recipient_customer = !recipient_user.support_agent? && !recipient_user.admin?
    
    # Determine title and message based on sender and recipient
    if is_customer && !is_recipient_customer
      # Customer to Agent
      title = "New message from #{sender_name}"
      notification_message = "Ticket ##{conversation.ticket_id}: #{truncate_message(message.content)}"
      icon = 'message-circle'
      action_url = "/support/conversations/#{conversation.id}"
    else
      # Agent to Customer
      title = "Customer Support replied"
      notification_message = "#{truncate_message(message.content)}"
      icon = 'headphones'
      action_url = "/support"
    end
    
    # Add package context if available
    if conversation.metadata&.dig('package_code')
      package_code = conversation.metadata['package_code']
      notification_message = "Package #{package_code}: #{notification_message}"
    end
    
    {
      title: title,
      message: notification_message,
      icon: icon,
      action_url: action_url
    }
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
  
  # NEW: Helper method to truncate message content for notifications
  def self.truncate_message(content, limit = 80)
    return '' unless content
    content.length > limit ? "#{content[0..limit-1]}..." : content
  end
end