# app/models/message.rb - Enhanced with ActionCable broadcasting and proper role detection

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
  
  # ENHANCED: ActionCable broadcasting callbacks for real-time messaging
  after_create :update_conversation_activity
  after_create_commit :broadcast_new_message
  after_update_commit :broadcast_message_update, if: :should_broadcast_update?
  
  # FIXED: Removed duplicate notification creation - handle this in controllers instead
  
  def from_support?
    # ENHANCED: Comprehensive support role detection with multiple fallback methods
    return false unless user
    
    begin
      # Method 1: Check using Rolify (primary method)
      return true if user.has_role?(:support)
      return true if user.has_role?(:admin)
      return true if user.has_role?(:agent)
      return true if user.has_role?(:super_admin)
      
      # Method 2: Check using email domain patterns
      if user.email.present?
        support_domains = ['support@', 'admin@', 'agent@', '@glt.co.ke', '@support.']
        return true if support_domains.any? { |domain| user.email.include?(domain) }
      end
      
      # Method 3: Check using user role/type fields
      if user.respond_to?(:role) && user.role.present?
        return true if ['support', 'admin', 'agent', 'super_admin', 'staff'].include?(user.role.downcase)
      end
      
      if user.respond_to?(:user_type) && user.user_type.present?
        return true if ['support', 'admin', 'agent', 'super_admin', 'staff'].include?(user.user_type.downcase)
      end
      
      # Method 4: Check using name patterns (last resort)
      if user.name.present?
        support_patterns = ['support', 'admin', 'agent', 'glt support']
        return true if support_patterns.any? { |pattern| user.name.downcase.include?(pattern) }
      end
      
      false
      
    rescue => e
      Rails.logger.error "Error checking support role for user #{user&.id}: #{e.message}"
      Rails.logger.error "User attributes: #{user&.attributes&.except('password_digest', 'encrypted_password')}"
      false
    end
  end
  
  def from_customer?
    !from_support?
  end
  
  def formatted_timestamp
    created_at.strftime('%H:%M')
  end

  def truncate_message(content, limit = 80)
    return '' unless content
    content.length > limit ? "#{content[0..limit-1]}..." : content
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
  
  # ENHANCED: Comprehensive real-time message broadcasting
  def broadcast_new_message
    return unless conversation.present?

    begin
      # Get all participants of this conversation
      conversation.participants.each do |participant|
        # Calculate unread message count for this participant
        unread_count = calculate_unread_messages_for_user(participant)
        
        # Broadcast to participant's message channel
        ActionCable.server.broadcast(
          "user_messages_#{participant.id}",
          {
            type: 'new_message',
            message: {
              id: id,
              content: content,
              message_type: message_type,
              metadata: metadata,
              created_at: created_at.iso8601,
              timestamp: formatted_timestamp,
              from_support: from_support?,
              is_system: is_system?,
              user: {
                id: user.id,
                name: user.display_name,
                role: from_support? ? 'support' : 'customer'
              }
            },
            conversation: {
              id: conversation.id,
              title: conversation.title || "Conversation #{conversation.id}",
              support_status: conversation.support_status,
              conversation_type: conversation.conversation_type
            },
            unread_messages_count: unread_count,
            timestamp: Time.current.iso8601
          }
        )
        
        Rails.logger.info "📡 New message broadcast sent to user #{participant.id} for conversation #{conversation.id}"
      end
      
      # Also broadcast to conversation-specific channel for real-time chat
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
          conversation_id: conversation.id
        }
      )
      
    rescue => e
      Rails.logger.error "❌ Failed to broadcast new message for conversation #{conversation.id}: #{e.message}"
      Rails.logger.error "Error details: #{e.class.name} - #{e.backtrace.first(3).join(', ')}"
    end
  end
  
  # ENHANCED: Broadcast message updates (like read status changes)
  def broadcast_message_update
    return unless conversation.present?

    begin
      conversation.participants.each do |participant|
        unread_count = calculate_unread_messages_for_user(participant)
        
        ActionCable.server.broadcast(
          "user_messages_#{participant.id}",
          {
            type: 'message_count_update',
            conversation_id: conversation.id,
            unread_messages_count: unread_count,
            updated_message_id: id,
            timestamp: Time.current.iso8601
          }
        )
      end
      
      Rails.logger.info "📡 Message update broadcast sent for conversation #{conversation.id}"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast message update for conversation #{conversation.id}: #{e.message}"
    end
  end
  
  # ENHANCED: Calculate total unread messages across all conversations for a user
  def calculate_unread_messages_for_user(user)
    total_unread = 0
    
    begin
      user.conversations.includes(:messages).each do |conv|
        last_read_at = conv.last_read_at_for(user)
        
        if last_read_at
          total_unread += conv.messages.where('created_at > ?', last_read_at).count
        else
          total_unread += conv.messages.count
        end
      end
      
      total_unread
    rescue => e
      Rails.logger.error "❌ Failed to calculate unread messages for user #{user.id}: #{e.message}"
      0
    end
  end

  # Helper method to determine if message update should be broadcast
  def should_broadcast_update?
    # Broadcast when message read status changes or other significant updates
    saved_change_to_read? || saved_change_to_content? || saved_change_to_message_type?
  end
end