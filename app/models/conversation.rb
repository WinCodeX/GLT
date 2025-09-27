# app/models/conversation.rb - Fixed with proper notification support
class Conversation < ApplicationRecord
  has_many :conversation_participants, dependent: :destroy
  has_many :users, through: :conversation_participants
  has_many :messages, dependent: :destroy
  
  validates :conversation_type, presence: true
  validate :validate_conversation_type
  
  before_create :set_initial_metadata
  before_save :update_last_activity
  
  scope :support_tickets, -> { where(conversation_type: 'support_ticket') }
  scope :direct_messages, -> { where(conversation_type: 'direct_message') }
  scope :active_support, -> { support_tickets.where("metadata->>'status' NOT IN (?)", ['resolved', 'closed']) }
  scope :recent, -> { order(last_activity_at: :desc) }
  
  def self.create_support_ticket(customer:, category: 'general', package: nil)
    Rails.logger.info "🎫 Creating support ticket for customer #{customer.id} with category: #{category}"
    
    transaction do
      ticket_id = generate_ticket_id
      Rails.logger.info "🔢 Generated ticket ID: #{ticket_id}"
      
      # Build metadata with package information
      metadata_hash = {
        ticket_id: ticket_id,
        status: 'created', # Start with 'created' instead of 'pending'
        category: category,
        priority: determine_priority(category),
        subject: generate_subject(category),
        created_at: Time.current.iso8601,
        updated_at: Time.current.iso8601
      }
      
      # Add package information to metadata if provided
      if package
        metadata_hash[:package_id] = package.id
        metadata_hash[:package_code] = package.code
        Rails.logger.info "📦 Added package to conversation: #{package.code}"
      end
      
      conversation = create!(
        conversation_type: 'support_ticket',
        title: "Support Ticket #{ticket_id}",
        metadata: metadata_hash
      )
      
      Rails.logger.info "💬 Created conversation #{conversation.id} with ticket ID #{ticket_id}"
      
      # Add customer as participant
      customer_participant = conversation.conversation_participants.create!(
        user: customer,
        role: 'customer',
        joined_at: Time.current
      )
      
      Rails.logger.info "👤 Added customer #{customer.id} as participant"
      
      # Create initial system message
      create_welcome_message(conversation)
      
      # Auto-assign agent and create their greeting message
      # This will trigger notifications to the customer
      assign_support_agent(conversation)
      
      Rails.logger.info "✅ Support ticket creation completed for conversation #{conversation.id}"
      
      conversation
    end
  rescue => e
    Rails.logger.error "❌ Failed to create support ticket: #{e.message}"
    Rails.logger.error "🔍 Error backtrace: #{e.backtrace.first(5).join(', ')}"
    raise e
  end
  
  def self.create_direct_message(user1, user2)
    existing = find_direct_message_between(user1, user2)
    return existing if existing
    
    transaction do
      conversation = create!(
        conversation_type: 'direct_message',
        title: "#{user1.display_name} & #{user2.display_name}",
        metadata: {
          participants: [user1.id, user2.id].sort,
          created_at: Time.current.iso8601
        }
      )
      
      [user1, user2].each do |user|
        conversation.conversation_participants.create!(
          user: user,
          role: 'participant',
          joined_at: Time.current
        )
      end
      
      conversation
    end
  end
  
  def self.find_direct_message_between(user1, user2)
    user1.conversations
         .direct_messages
         .joins(:conversation_participants)
         .where(conversation_participants: { user_id: user2.id })
         .first
  end
  
  # Support ticket methods
  def support_ticket?
    conversation_type == 'support_ticket'
  end
  
  def direct_message?
    conversation_type == 'direct_message'
  end
  
  def ticket_id
    metadata&.dig('ticket_id') || metadata&.dig(:ticket_id)
  end
  
  def status
    metadata&.dig('status') || metadata&.dig(:status) || 'unknown'
  end
  
  def category
    metadata&.dig('category') || metadata&.dig(:category) || 'general'
  end
  
  def priority
    metadata&.dig('priority') || metadata&.dig(:priority) || 'normal'
  end
  
  def customer
    conversation_participants.find_by(role: 'customer')&.user
  end
  
  def assigned_agent
    conversation_participants.find_by(role: 'agent')&.user
  end
  
  def other_participant(current_user)
    return nil unless direct_message?
    users.where.not(id: current_user.id).first
  end
  
  def last_message
    messages.order(:created_at).last
  end
  
  def unread_count_for(user)
    participant = conversation_participants.find_by(user: user)
    return 0 unless participant
    
    messages.where('created_at > ?', participant.last_read_at || participant.joined_at)
            .where.not(user: user)
            .count
  end
  
  def mark_read_by(user)
    participant = conversation_participants.find_by(user: user)
    participant&.update!(last_read_at: Time.current)
  end
  
  def update_support_status(new_status)
    return unless support_ticket?
    
    Rails.logger.info "🔄 Updating conversation #{id} status from '#{status}' to '#{new_status}'"
    
    self.metadata = (metadata || {}).merge({
      'status' => new_status,
      'updated_at' => Time.current.iso8601
    })
    save!
    
    Rails.logger.info "✅ Updated conversation #{id} status to '#{new_status}'"
  end
  
  private
  
  def self.generate_ticket_id
    loop do
      ticket_id = "SP#{SecureRandom.hex(4).upcase}"
      break ticket_id unless exists?(["metadata->>'ticket_id' = ?", ticket_id])
    end
  end
  
  def self.generate_subject(category)
    case category.to_s
    when 'package_inquiry' then 'Package Inquiry'
    when 'follow_up' then 'Package Follow-up'
    when 'complaint' then 'Issue Report'
    when 'technical' then 'Technical Support'
    else 'General Support'
    end
  end
  
  def self.determine_priority(category)
    case category.to_s
    when 'complaint', 'technical' then 'high'
    when 'package_inquiry' then 'normal'
    else 'normal'
    end
  end
  
  # FIXED: Create welcome message but don't trigger notifications for it
  def self.create_welcome_message(conversation)
    # Use any user with support role as system user
    system_user = find_support_user_for_system_messages
    
    Rails.logger.info "📢 Creating welcome message with user #{system_user&.id}"
    
    conversation.messages.create!(
      user: system_user,
      content: "Thank you for contacting support! Your ticket #{conversation.ticket_id} has been created. Connecting you with an agent...",
      message_type: 'system',
      is_system: true
    )
  rescue => e
    Rails.logger.error "❌ Failed to create welcome message: #{e.message}"
  end
  
  # FIXED: Assign agent and create their message (this WILL trigger notifications)
  def self.assign_support_agent(conversation)
    agent = find_available_agent
    
    if agent
      Rails.logger.info "👩‍💼 Assigning agent #{agent.id} (#{agent.display_name}) to conversation #{conversation.id}"
      
      # Add agent as participant
      conversation.conversation_participants.create!(
        user: agent,
        role: 'agent',
        joined_at: Time.current
      )
      
      # Update status to indicate agent is assigned
      conversation.update_support_status('in_progress')
      
      # Create agent greeting message - this WILL trigger notifications to customer
      Rails.logger.info "💬 Creating agent greeting message (this will trigger customer notification)"
      
      agent_message = conversation.messages.create!(
        user: agent,
        content: "Hi! I'm #{agent.display_name} and I'll be helping you today. How can I assist you?",
        message_type: 'text',
        is_system: false  # This is NOT a system message, so it will trigger notifications
      )
      
      Rails.logger.info "✅ Created agent message #{agent_message.id} - notifications should be triggered"
      
    else
      Rails.logger.warn "⚠️ No available support agent found for conversation #{conversation.id}"
    end
    
    agent
  rescue => e
    Rails.logger.error "❌ Failed to assign support agent: #{e.message}"
    Rails.logger.error "🔍 Error backtrace: #{e.backtrace.first(3).join(', ')}"
    nil
  end
  
  # FIXED: Better agent finding with more fallbacks and logging
  def self.find_available_agent
    Rails.logger.info "🔍 Looking for available support agent..."
    
    # Try to find agents using different methods
    agents_found = []
    
    # Method 1: Rolify with role :support
    begin
      rolify_agents = User.with_role(:support).limit(10)
      agents_found.concat(rolify_agents.to_a)
      Rails.logger.info "📋 Found #{rolify_agents.count} users with :support role via Rolify"
    rescue => e
      Rails.logger.warn "⚠️ Rolify support role query failed: #{e.message}"
    end
    
    # Method 2: Check for support email domains
    begin
      email_agents = User.where("email LIKE ? OR email LIKE ?", '%support@%', '%@glt.co.ke').limit(10)
      agents_found.concat(email_agents.to_a)
      Rails.logger.info "📧 Found #{email_agents.count} users with support email patterns"
    rescue => e
      Rails.logger.warn "⚠️ Email-based agent search failed: #{e.message}"
    end
    
    # Method 3: Check for role field
    begin
      if User.column_names.include?('role')
        role_agents = User.where(role: ['support', 'admin', 'agent']).limit(10)
        agents_found.concat(role_agents.to_a)
        Rails.logger.info "🏷️ Found #{role_agents.count} users with support role field"
      end
    rescue => e
      Rails.logger.warn "⚠️ Role field agent search failed: #{e.message}"
    end
    
    # Remove duplicates and get the first available agent
    unique_agents = agents_found.uniq(&:id)
    Rails.logger.info "👥 Total unique potential agents found: #{unique_agents.size}"
    
    if unique_agents.empty?
      Rails.logger.error "❌ No support agents found in system!"
      return nil
    end
    
    # For now, just return the first agent found
    # Later you can add logic for load balancing, online status, etc.
    selected_agent = unique_agents.first
    
    Rails.logger.info "✅ Selected agent: #{selected_agent.id} (#{selected_agent.display_name}) - #{selected_agent.email}"
    
    selected_agent
  end
  
  # FIXED: Find support user for system messages
  def self.find_support_user_for_system_messages
    # Try different methods to find a support user for system messages
    support_user = nil
    
    begin
      support_user = User.with_role(:support).first
    rescue
      # Fallback if Rolify fails
    end
    
    support_user ||= User.where("email LIKE ?", '%support@%').first
    support_user ||= User.where("email LIKE ?", '%@glt.co.ke').first
    support_user ||= User.first # Ultimate fallback
    
    Rails.logger.info "🤖 Using user #{support_user&.id} for system messages"
    support_user
  end
  
  def validate_conversation_type
    valid_types = %w[direct_message support_ticket group_chat]
    unless valid_types.include?(conversation_type)
      errors.add(:conversation_type, 'must be a valid type')
    end
  end
  
  def set_initial_metadata
    self.metadata ||= {}
    self.last_activity_at ||= Time.current
  end
  
  def update_last_activity
    self.last_activity_at = Time.current if changed?
  end
end