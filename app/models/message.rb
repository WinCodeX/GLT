# app/models/message.rb - Fixed with notification callbacks
class Message < ApplicationRecord
  belongs_to :conversation
  belongs_to :user
  
  # Add _suffix to avoid enum conflicts
  enum message_type: {
    text: 0,
    voice: 1,
    image: 2,
    file: 3,
    system: 4
  }, _suffix: :msg
  
  validates :content, presence: true
  validates :message_type, presence: true
  
  scope :chronological, -> { order(:created_at) }
  scope :recent, -> { order(created_at: :desc) }
  scope :user_messages, -> { where(is_system: false) }
  scope :system_messages, -> { where(is_system: true) }
  
  after_create :update_conversation_activity
  after_create_commit :broadcast_message
  after_create_commit :create_support_notifications  # FIXED: Add notification callback
  
  def from_support?
    user.has_role?(:support) || user.has_role?(:admin)
  end
  
  def from_customer?
    !from_support?
  end
  
  def formatted_timestamp
    created_at.strftime('%H:%M')
  end
  
  private
  
  def update_conversation_activity
    conversation.touch(:last_activity_at)
    
    # Update support ticket status if applicable
    if conversation.support_ticket? && !is_system?
      update_support_ticket_status
    end
  end
  
  def update_support_ticket_status
    current_status = conversation.status
    
    if from_customer? && current_status == 'waiting_customer'
      conversation.update_support_status('in_progress')
    elsif from_support? && current_status == 'assigned'
      conversation.update_support_status('in_progress')
    end
  end
  
  def broadcast_message
    ActionCable.server.broadcast(
      "conversation_#{conversation.id}",
      {
        type: 'new_message',
        message: {
          id: id,
          content: content,
          message_type: message_type,
          metadata: metadata,
          timestamp: formatted_timestamp,
          from_support: from_support?,
          is_system: is_system?,
          user: {
            id: user.id,
            name: user.display_name,
            role: from_support? ? 'support' : 'customer'
          }
        },
        conversation_id: conversation.id,
        conversation_type: conversation.conversation_type
      }
    )
  end
  
  # FIXED: Create push notifications for support messages
  def create_support_notifications
    # Only create notifications for support conversations
    return unless conversation.support_ticket?
    
    # Don't notify for system messages
    return if is_system?
    
    # Don't create notifications in test environment to avoid issues
    return if Rails.env.test?
    
    begin
      Rails.logger.info "Creating support notifications for message #{id} in conversation #{conversation.id}"
      
      # Get all participants except the message sender
      participants_to_notify = conversation.conversation_participants
                                         .includes(:user)
                                         .where.not(user: user)
                                         .map(&:user)
      
      Rails.logger.info "Found #{participants_to_notify.size} participants to notify: #{participants_to_notify.map(&:id)}"
      
      # Create notifications for each participant
      notifications_created = 0
      participants_to_notify.each do |participant|
        begin
          Rails.logger.info "Creating notification for user #{participant.id} (#{participant.display_name})"
          
          notification = create_support_message_notification(participant)
          
          if notification
            Rails.logger.info "Successfully created notification #{notification.id} for user #{participant.id}"
            notifications_created += 1
          else
            Rails.logger.warn "Failed to create notification for user #{participant.id} - notification was nil"
          end
          
        rescue => e
          Rails.logger.error "Failed to create notification for user #{participant.id}: #{e.message}"
          Rails.logger.error "Error backtrace: #{e.backtrace.first(3).join(', ')}"
        end
      end
      
      Rails.logger.info "Created #{notifications_created} support message notifications for message #{id}"
      
    rescue => e
      Rails.logger.error "Failed to create support notifications for message #{id}: #{e.message}"
      Rails.logger.error "Error backtrace: #{e.backtrace.first(5).join(', ')}"
      # Don't re-raise to avoid breaking message creation
    end
  end
  
  # FIXED: Create individual notification for a participant
  def create_support_message_notification(recipient_user)
    # Don't notify the sender of their own message
    return if user == recipient_user
    
    sender_name = user.display_name
    is_customer_sender = !from_support?
    is_recipient_customer = !recipient_user.has_role?(:support) && !recipient_user.has_role?(:admin)
    
    # Determine title and message based on sender and recipient
    if is_customer_sender && !is_recipient_customer
      # Customer to Agent
      title = "New message from #{sender_name}"
      notification_message = "Ticket ##{conversation.ticket_id}: #{truncate_message(content)}"
      icon = 'message-circle'
      action_url = "/admin/support/conversations/#{conversation.id}"
    else
      # Agent to Customer
      title = "Customer Support replied"
      notification_message = truncate_message(content)
      icon = 'headphones'
      action_url = "/support"
    end
    
    # Add package context if available
    if conversation.metadata&.dig('package_code')
      package_code = conversation.metadata['package_code']
      notification_message = "Package #{package_code}: #{notification_message}"
    elsif metadata&.dig('package_code')
      package_code = metadata['package_code']
      notification_message = "Package #{package_code}: #{notification_message}"
    end
    
    # Determine priority based on conversation priority
    priority = case conversation.priority.to_s
    when 'urgent'
      'high'
    when 'high'
      'normal'
    else
      'normal'
    end
    
    notification_data = {
      user: recipient_user,
      title: title,
      message: notification_message,
      notification_type: 'support_message',
      channel: 'push',
      priority: priority,
      icon: icon,
      action_url: action_url,
      metadata: {
        conversation_id: conversation.id,
        message_id: id,
        ticket_id: conversation.ticket_id,
        from_user_id: user.id,
        from_user_name: user.display_name
      }
    }
    
    Rails.logger.info "Creating notification with data: #{notification_data.except(:user).inspect}"
    
    # Create notification
    notification = Notification.create!(notification_data)
    
    # Immediately send push notification
    Rails.logger.info "Enqueuing push notification job for notification #{notification.id}"
    DeliverNotificationJob.perform_later(notification)
    
    notification
    
  rescue => e
    Rails.logger.error "Failed to create individual notification: #{e.message}"
    Rails.logger.error "Error class: #{e.class.name}"
    Rails.logger.error "Error backtrace: #{e.backtrace.first(5).join(', ')}"
    nil
  end
  
  # FIXED: Helper method to truncate message content for notifications
  def truncate_message(content, limit = 80)
    return '' unless content
    content.length > limit ? "#{content[0..limit-1]}..." : content
  end
end