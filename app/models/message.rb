# app/models/message.rb - Fixed with proper role detection and notification handling
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
    # FIXED: Use Rolify properly with multiple role checking methods
    return false unless user
    
    # Check using Rolify (which you're using based on Conversation model)
    return true if user.has_role?(:support)
    return true if user.has_role?(:admin)
    
    # Alternative check using email domain (backup method)
    return true if user.email&.include?('support@') || user.email&.include?('@glt.co.ke')
    
    # Check using user type/role field if it exists
    return true if user.respond_to?(:role) && ['support', 'admin', 'agent'].include?(user.role)
    return true if user.respond_to?(:user_type) && ['support', 'admin', 'agent'].include?(user.user_type)
    
    false
  rescue => e
    Rails.logger.error "Error checking support role for user #{user&.id}: #{e.message}"
    false
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
  
  # FIXED: Create push notifications for support messages with extensive logging
  def create_support_notifications
    # Only create notifications for support conversations
    unless conversation.support_ticket?
      Rails.logger.debug "Skipping notifications - not a support ticket (type: #{conversation.conversation_type})"
      return
    end
    
    # Don't notify for system messages
    if is_system?
      Rails.logger.debug "Skipping notifications - system message"
      return
    end
    
    # Don't create notifications in test environment
    if Rails.env.test?
      Rails.logger.debug "Skipping notifications - test environment"
      return
    end
    
    begin
      Rails.logger.info "🔔 Creating support notifications for message #{id} in conversation #{conversation.id}"
      Rails.logger.info "📝 Message content: #{content[0..50]}#{'...' if content.length > 50}"
      Rails.logger.info "👤 Sender: #{user.display_name} (ID: #{user.id}) - Support: #{from_support?}"
      
      # Get all participants except the message sender
      participants_to_notify = conversation.conversation_participants
                                         .includes(:user)
                                         .where.not(user: user)
      
      Rails.logger.info "👥 Found #{participants_to_notify.size} participants to potentially notify"
      
      if participants_to_notify.empty?
        Rails.logger.warn "⚠️ No participants found to notify for conversation #{conversation.id}"
        return
      end
      
      # Create notifications for each participant
      notifications_created = 0
      participants_to_notify.each do |participant|
        participant_user = participant.user
        
        begin
          Rails.logger.info "📮 Creating notification for user #{participant_user.id} (#{participant_user.display_name}) - Role: #{participant.role}"
          
          # Check if user has push tokens
          if participant_user.respond_to?(:push_tokens)
            token_count = participant_user.push_tokens.active.count rescue 0
            Rails.logger.info "📱 User has #{token_count} active push tokens"
          end
          
          notification = create_support_message_notification(participant_user)
          
          if notification&.persisted?
            Rails.logger.info "✅ Successfully created notification #{notification.id} for user #{participant_user.id}"
            notifications_created += 1
          else
            Rails.logger.error "❌ Failed to create notification for user #{participant_user.id} - notification not persisted"
          end
          
        rescue => e
          Rails.logger.error "❌ Exception creating notification for user #{participant_user.id}: #{e.message}"
          Rails.logger.error "🔍 Error backtrace: #{e.backtrace.first(3).join(', ')}"
        end
      end
      
      Rails.logger.info "📊 Created #{notifications_created}/#{participants_to_notify.size} support message notifications for message #{id}"
      
    rescue => e
      Rails.logger.error "💥 Failed to create support notifications for message #{id}: #{e.message}"
      Rails.logger.error "🔍 Error class: #{e.class.name}"
      Rails.logger.error "🔍 Error backtrace: #{e.backtrace.first(5).join(', ')}"
      # Don't re-raise to avoid breaking message creation
    end
  end
  
  # FIXED: Create individual notification with better error handling
  def create_support_message_notification(recipient_user)
    # Double-check we're not notifying the sender
    if user == recipient_user
      Rails.logger.debug "Skipping notification - recipient is the sender"
      return nil
    end
    
    sender_name = user.display_name
    is_customer_sender = from_customer?
    
    # FIXED: Better role detection for recipient
    is_recipient_support = begin
      recipient_user.has_role?(:support) || 
      recipient_user.has_role?(:admin) ||
      recipient_user.email&.include?('support@') ||
      recipient_user.email&.include?('@glt.co.ke')
    rescue
      false
    end
    
    Rails.logger.info "🎯 Notification target - Customer sender: #{is_customer_sender}, Recipient is support: #{is_recipient_support}"
    
    # Determine title and message based on sender and recipient
    if is_customer_sender && is_recipient_support
      # Customer to Agent
      title = "New message from #{sender_name}"
      notification_message = "Ticket ##{conversation.ticket_id}: #{truncate_message(content)}"
      icon = 'message-circle'
      action_url = "/admin/support/conversations/#{conversation.id}"
    elsif !is_customer_sender && !is_recipient_support
      # Agent to Customer
      title = "Customer Support replied"
      notification_message = truncate_message(content)
      icon = 'headphones'
      action_url = "/support"
    else
      # Fallback for unclear roles
      title = "New support message"
      notification_message = "#{sender_name}: #{truncate_message(content)}"
      icon = 'message-circle'
      action_url = "/support"
    end
    
    # Add package context if available
    package_code = conversation.metadata&.dig('package_code') || 
                  conversation.metadata&.dig(:package_code) ||
                  metadata&.dig('package_code') ||
                  metadata&.dig(:package_code)
    
    if package_code
      notification_message = "Package #{package_code}: #{notification_message}"
    end
    
    # Determine priority
    priority = case conversation.priority.to_s
    when 'urgent' then 'high'
    when 'high' then 'normal'
    else 'normal'
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
        from_user_name: user.display_name,
        package_code: package_code
      }.compact
    }
    
    Rails.logger.info "📋 Creating notification with title: '#{title}' and message: '#{notification_message}'"
    
    # Create notification
    notification = Notification.create!(notification_data)
    Rails.logger.info "💾 Notification #{notification.id} created successfully"
    
    # Immediately send push notification with logging
    Rails.logger.info "🚀 Enqueuing push notification job for notification #{notification.id}"
    
    # Try both async and sync delivery for debugging
    if Rails.env.development?
      # In development, also try immediate delivery for testing
      begin
        Rails.logger.info "🧪 Attempting immediate push delivery for debugging"
        DeliverNotificationJob.perform_now(notification)
      rescue => e
        Rails.logger.error "🔥 Immediate delivery failed: #{e.message}"
        # Fall back to async
        DeliverNotificationJob.perform_later(notification)
      end
    else
      DeliverNotificationJob.perform_later(notification)
    end
    
    notification
    
  rescue => e
    Rails.logger.error "💀 Failed to create individual notification for user #{recipient_user&.id}: #{e.message}"
    Rails.logger.error "🔍 Error class: #{e.class.name}"
    Rails.logger.error "🔍 Notification data: #{notification_data.inspect}" if defined?(notification_data)
    Rails.logger.error "🔍 Error backtrace: #{e.backtrace.first(5).join(', ')}"
    nil
  end
  
  # Helper method to truncate message content for notifications
  def truncate_message(content, limit = 80)
    return '' unless content
    content.length > limit ? "#{content[0..limit-1]}..." : content
  end
end