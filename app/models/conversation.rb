# app/models/conversation.rb
class Conversation < ApplicationRecord
  has_many :conversation_participants, dependent: :destroy
  has_many :users, through: :conversation_participants
  has_many :messages, dependent: :destroy
  belongs_to :customer, class_name: 'User', optional: true
  
  validates :conversation_type, presence: true
  validate :validate_conversation_type
  
  before_create :set_initial_metadata
  before_save :update_last_activity
  
  scope :support_tickets, -> { where(conversation_type: 'support_ticket') }
  scope :direct_messages, -> { where(conversation_type: 'direct_message') }
  scope :active_support, -> { support_tickets.where.not(current_ticket_id: nil) }
  scope :recent, -> { order(last_activity_at: :desc) }
  
  # FIXED: Find or create ONE master support conversation per user
  def self.find_or_create_support_conversation(customer:)
    Rails.logger.info "🔍 Looking for existing support conversation for user #{customer.id}"
    
    # Find existing support conversation for this user
    conversation = support_tickets.find_by(customer_id: customer.id)
    
    if conversation
      Rails.logger.info "✅ Found existing support conversation: #{conversation.id}"
      return conversation
    end
    
    Rails.logger.info "📝 Creating new master support conversation for user #{customer.id}"
    
    transaction do
      conversation = create!(
        conversation_type: 'support_ticket',
        customer_id: customer.id,
        title: "Support for #{customer.display_name}",
        tickets: [],
        metadata: {
          created_at: Time.current.iso8601,
          total_tickets: 0
        }
      )
      
      # Add customer as participant
      conversation.conversation_participants.create!(
        user: customer,
        role: 'customer',
        joined_at: Time.current
      )
      
      Rails.logger.info "✅ Created master conversation #{conversation.id}"
      conversation
    end
  end
  
  # FIXED: Create a new ticket within existing conversation
  def self.create_support_ticket(customer:, category: 'general', package: nil)
    Rails.logger.info "🎫 Creating support ticket for customer #{customer.id} with category: #{category}"
    
    transaction do
      # Find or create master conversation
      conversation = find_or_create_support_conversation(customer: customer)
      
      # Generate new ticket
      ticket_id = generate_ticket_id
      Rails.logger.info "🔢 Generated ticket ID: #{ticket_id}"
      
      # Build ticket data
      ticket_data = {
        ticket_id: ticket_id,
        category: category,
        priority: determine_priority(category),
        subject: generate_subject(category),
        status: 'created',
        created_at: Time.current.iso8601,
        package_id: package&.id,
        package_code: package&.code
      }.compact
      
      # Add ticket to conversation
      conversation.tickets ||= []
      conversation.tickets << ticket_data
      conversation.current_ticket_id = ticket_id
      conversation.title = "Support Ticket #{ticket_id}"
      
      # Update metadata
      conversation.metadata ||= {}
      conversation.metadata['total_tickets'] = conversation.tickets.size
      conversation.metadata['status'] = 'created'
      conversation.metadata['category'] = category
      conversation.metadata['priority'] = ticket_data[:priority]
      conversation.metadata['ticket_id'] = ticket_id
      
      # Add package info to metadata for backward compatibility
      if package
        conversation.metadata['package_id'] = package.id
        conversation.metadata['package_code'] = package.code
      end
      
      conversation.save!
      
      Rails.logger.info "💬 Added ticket #{ticket_id} to conversation #{conversation.id}"
      
      # Create system message for new ticket
      create_new_ticket_message(conversation, ticket_data)
      
      # Auto-assign agent silently
      agent = assign_support_agent_silently(conversation)
      
      Rails.logger.info "✅ Ticket creation completed"
      
      conversation
    end
  rescue => e
    Rails.logger.error "❌ Failed to create support ticket: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    raise e
  end
  
  # Get current active ticket
  def current_ticket
    return nil unless current_ticket_id
    tickets&.find { |t| t['ticket_id'] == current_ticket_id }
  end
  
  # Get all tickets for this conversation
  def all_tickets
    tickets || []
  end
  
  # Close current ticket (not entire conversation)
  def close_current_ticket
    return unless current_ticket_id
    
    Rails.logger.info "🔒 Closing ticket #{current_ticket_id} in conversation #{id}"
    
    # Update ticket status in tickets array
    if tickets.present?
      ticket = tickets.find { |t| t['ticket_id'] == current_ticket_id }
      if ticket
        ticket['status'] = 'closed'
        ticket['closed_at'] = Time.current.iso8601
      end
    end
    
    # Update metadata for backward compatibility
    metadata['status'] = 'closed'
    
    # Clear current ticket (ready for new ticket)
    self.current_ticket_id = nil
    
    save!
    Rails.logger.info "✅ Ticket closed, conversation remains open"
  end
  
  # Reopen ticket or create new one
  def reopen_or_create_ticket(category: 'general', package: nil)
    Rails.logger.info "🔄 Reopening or creating new ticket in conversation #{id}"
    
    # Generate new ticket
    ticket_id = self.class.generate_ticket_id
    
    ticket_data = {
      ticket_id: ticket_id,
      category: category,
      priority: self.class.determine_priority(category),
      subject: self.class.generate_subject(category),
      status: 'created',
      created_at: Time.current.iso8601,
      package_id: package&.id,
      package_code: package&.code
    }.compact
    
    # Add ticket to array
    self.tickets ||= []
    self.tickets << ticket_data
    self.current_ticket_id = ticket_id
    self.title = "Support Ticket #{ticket_id}"
    
    # Update metadata
    metadata['total_tickets'] = tickets.size
    metadata['status'] = 'created'
    metadata['category'] = category
    metadata['priority'] = ticket_data[:priority]
    metadata['ticket_id'] = ticket_id
    
    if package
      metadata['package_id'] = package.id
      metadata['package_code'] = package.code
    end
    
    save!
    
    # Create system message
    self.class.create_new_ticket_message(self, ticket_data)
    
    Rails.logger.info "✅ New ticket #{ticket_id} created"
    
    self
  end
  
  # Support ticket methods
  def support_ticket?
    conversation_type == 'support_ticket'
  end
  
  def direct_message?
    conversation_type == 'direct_message'
  end
  
  def ticket_id
    current_ticket_id || metadata&.dig('ticket_id')
  end
  
  def status
    metadata&.dig('status') || 'unknown'
  end
  
  def category
    metadata&.dig('category') || 'general'
  end
  
  def priority
    metadata&.dig('priority') || 'normal'
  end
  
  def customer
    super || conversation_participants.find_by(role: 'customer')&.user
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
    
    Rails.logger.info "🔄 Updating conversation #{id} status to '#{new_status}'"
    
    # Update current ticket status
    if current_ticket_id && tickets.present?
      ticket = tickets.find { |t| t['ticket_id'] == current_ticket_id }
      ticket['status'] = new_status if ticket
    end
    
    # Update metadata
    self.metadata = (metadata || {}).merge({
      'status' => new_status,
      'updated_at' => Time.current.iso8601
    })
    
    # If closing, clear current_ticket_id
    self.current_ticket_id = nil if new_status == 'closed'
    
    save!
  end
  
  def send_agent_greeting_if_needed
    return unless support_ticket?
    return if status != 'created'
    return if messages.where(is_system: false).where.not(user: customer).exists?
    
    agent = assigned_agent
    return unless agent
    
    Rails.logger.info "💬 Sending agent greeting for conversation #{id}"
    
    agent_message = messages.create!(
      user: agent,
      content: "Hi! I'm #{agent.display_name} and I'll be helping you today. How can I assist you?",
      message_type: 'text',
      is_system: false
    )
    
    agent_message
  end
  
  private
  
  def self.generate_ticket_id
    loop do
      ticket_id = "SP#{SecureRandom.hex(4).upcase}"
      break ticket_id unless exists?(["tickets @> ?", [{ticket_id: ticket_id}].to_json])
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
  
  def self.create_new_ticket_message(conversation, ticket_data)
    system_user = find_support_user_for_system_messages
    
    content = if conversation.tickets.size == 1
      "Thank you for contacting support! Your ticket #{ticket_data[:ticket_id]} has been created. An agent will be with you shortly..."
    else
      "New support ticket #{ticket_data[:ticket_id]} created for: #{ticket_data[:subject]}"
    end
    
    conversation.messages.create!(
      user: system_user,
      content: content,
      message_type: 'system',
      is_system: true,
      metadata: { ticket_id: ticket_data[:ticket_id], type: 'ticket_created' }
    )
  rescue => e
    Rails.logger.error "❌ Failed to create ticket message: #{e.message}"
  end
  
  def self.assign_support_agent_silently(conversation)
    agent = find_available_agent
    
    if agent
      Rails.logger.info "👩‍💼 Assigning agent #{agent.id} to conversation #{conversation.id}"
      
      unless conversation.conversation_participants.exists?(user: agent, role: 'agent')
        conversation.conversation_participants.create!(
          user: agent,
          role: 'agent',
          joined_at: Time.current
        )
      end
      
      conversation.update_support_status('pending')
    else
      Rails.logger.warn "⚠️ No available agent found"
    end
    
    agent
  rescue => e
    Rails.logger.error "❌ Failed to assign agent: #{e.message}"
    nil
  end
  
  def self.find_available_agent
    agents_found = []
    
    begin
      agents_found.concat(User.with_role(:support).limit(10).to_a)
    rescue
    end
    
    begin
      agents_found.concat(User.where("email LIKE ? OR email LIKE ?", '%support@%', '%@glt.co.ke').limit(10).to_a)
    rescue
    end
    
    unique_agents = agents_found.uniq(&:id)
    unique_agents.first
  end
  
  def self.find_support_user_for_system_messages
    support_user = nil
    
    begin
      support_user = User.with_role(:support).first
    rescue
    end
    
    support_user ||= User.where("email LIKE ?", '%support@%').first
    support_user ||= User.where("email LIKE ?", '%@glt.co.ke').first
    support_user ||= User.first
    
    support_user
  end
  
  # Direct message methods
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