# app/models/message.rb - Fixed with ActionCable broadcasting

class Message < ApplicationRecord
  belongs_to :conversation
  belongs_to :user
  
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
  scope :user_messages, -> { where.not(message_type: 'system') }
  scope :system_messages, -> { where(message_type: 'system') }
  scope :undelivered, -> { where(delivered_at: nil).where.not(sent_at: nil) }
  
  before_create :set_sent_at
  after_create :update_conversation_activity
  
  # CRITICAL FIX: Broadcast message to all channels after creation
  after_create_commit :broadcast_to_channels
  
  def from_support?
    return false unless user
    
    begin
      # Method 1: Check using Rolify (primary method)
      if user.respond_to?(:has_role?)
        return true if user.has_role?(:support)
        return true if user.has_role?(:admin)
        return true if user.has_role?(:agent)
        return true if user.has_role?(:super_admin)
      end
      
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
      
      # Method 4: Check using display name patterns (last resort)
      if user.respond_to?(:display_name) && user.display_name.present?
        support_patterns = ['support', 'admin', 'agent', 'glt support', 'customer support']
        return true if support_patterns.any? { |pattern| user.display_name.downcase.include?(pattern) }
      end
      
      # Method 5: Check using name patterns (last resort)
      if user.respond_to?(:name) && user.name.present?
        support_patterns = ['support', 'admin', 'agent', 'glt support', 'customer support']
        return true if support_patterns.any? { |pattern| user.name.downcase.include?(pattern) }
      end
      
      false
      
    rescue => e
      Rails.logger.error "Error checking support role for user #{user&.id}: #{e.message}"
      Rails.logger.error "User attributes available: #{user&.attributes&.keys&.reject { |k| k.include?('password') }}"
      false
    end
  end
  
  def from_customer?
    !from_support?
  end
  
  def is_system?
    message_type == 'system'
  end
  
  def formatted_timestamp
    created_at.strftime('%H:%M')
  end

  def truncate_content(limit = 80)
    return '' unless content.present?
    content.length > limit ? "#{content[0..limit-1]}..." : content
  end
  
  def sender_display_name
    return 'System' if is_system?
    return 'Unknown User' unless user
    
    user.display_name.presence || 
    user.name.presence || 
    user.email.presence || 
    'Unknown User'
  end
  
  def preview_content(limit = 100)
    case message_type
    when 'text'
      truncate_content(limit)
    when 'image'
      '📷 Image'
    when 'voice'
      '🎤 Voice message'
    when 'file'
      "📎 #{metadata&.dig('filename') || 'File'}"
    when 'system'
      content
    else
      content.presence || 'Message'
    end
  end
  
  private
  
  def set_sent_at
    self.sent_at ||= Time.current
  end
  
  def update_conversation_activity
    begin
      conversation.touch(:last_activity_at) if conversation.respond_to?(:last_activity_at)
      
      if conversation.respond_to?(:support_ticket?) && conversation.support_ticket? && !is_system?
        update_support_ticket_status
      end
      
    rescue => e
      Rails.logger.error "Failed to update conversation activity for message #{id}: #{e.message}"
    end
  end
  
  def update_support_ticket_status
    return unless conversation.respond_to?(:status) && conversation.respond_to?(:update_support_status)
    
    current_status = conversation.status
    
    case current_status
    when 'waiting_customer'
      if from_customer?
        conversation.update_support_status('in_progress')
        Rails.logger.info "Updated ticket status from waiting_customer to in_progress (customer replied)"
      end
    when 'assigned', 'pending'
      if from_support?
        conversation.update_support_status('in_progress')
        Rails.logger.info "Updated ticket status from #{current_status} to in_progress (support replied)"
      end
    end
    
  rescue => e
    Rails.logger.error "Failed to update support ticket status for message #{id}: #{e.message}"
  end
  
  # CRITICAL FIX: Broadcast message to all relevant ActionCable channels
  def broadcast_to_channels
    begin
      Rails.logger.info "Broadcasting message #{id} to ActionCable channels..."
      
      # Use the UserNotificationsChannel class method to broadcast
      if defined?(UserNotificationsChannel)
        UserNotificationsChannel.broadcast_new_message(self)
      else
        Rails.logger.error "UserNotificationsChannel not found - cannot broadcast message #{id}"
      end
      
    rescue => e
      Rails.logger.error "Failed to broadcast message #{id} to channels: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end
  end
end