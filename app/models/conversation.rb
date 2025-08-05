# app/models/conversation.rb (CREATE this new file)
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
    transaction do
      ticket_id = generate_ticket_id
      
      conversation = create!(
        conversation_type: 'support_ticket',
        title: "Support Ticket #{ticket_id}",
        metadata: {
          ticket_id: ticket_id,
          status: 'pending',
          category: category,
          priority: determine_priority(category),
          package_id: package&.id,
          subject: generate_subject(category),
          created_at: Time.current.iso8601
        }
      )
      
      # Add customer
      conversation.conversation_participants.create!(
        user: customer,
        role: 'customer',
        joined_at: Time.current
      )
      
      # Create welcome message
      create_welcome_message(conversation)
      
      # Auto-assign agent
      assign_support_agent(conversation)
      
      conversation
    end
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
    metadata['ticket_id']
  end
  
  def status
    metadata['status']
  end
  
  def category
    metadata['category']
  end
  
  def priority
    metadata['priority']
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
    
    self.metadata = metadata.merge({
      'status' => new_status,
      'updated_at' => Time.current.iso8601
    })
    save!
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
    when 'inquiry' then 'Package Inquiry'
    when 'follow_up' then 'Package Follow-up'
    when 'complaint' then 'Issue Report'
    when 'technical' then 'Technical Support'
    else 'General Support'
    end
  end
  
  def self.determine_priority(category)
    case category.to_s
    when 'complaint', 'technical' then 'high'
    else 'normal'
    end
  end
  
  def self.create_welcome_message(conversation)
    # Use any user with support role as system user
    system_user = User.with_role(:support).first || User.first
    
    conversation.messages.create!(
      user: system_user,
      content: "Thank you for contacting support! Your ticket #{conversation.ticket_id} has been created. Connecting you with an agent...",
      message_type: 'system',
      is_system: true
    )
  end
  
  def self.assign_support_agent(conversation)
    agent = find_available_agent
    
    if agent
      conversation.conversation_participants.create!(
        user: agent,
        role: 'agent',
        joined_at: Time.current
      )
      
      conversation.update_support_status('assigned')
      
      conversation.messages.create!(
        user: agent,
        content: "Hi! I'm #{agent.display_name} and I'll be helping you today. How can I assist you?",
        message_type: 'text',
        is_system: false
      )
    end
    
    agent
  end
  
  def self.find_available_agent
    # Find available support agents using Rolify
    available_agents = User.with_role(:support)
                          .where(online: true)
                          .left_joins(conversation_participants: :conversation)
                          .where(conversations: { conversation_type: 'support_ticket' })
                          .where(conversation_participants: { role: 'agent' })
                          .where("conversations.metadata->>'status' IN (?)", ['assigned', 'in_progress', 'waiting_customer'])
                          .group('users.id')
                          .having('COUNT(conversations.id) < ?', 5)
                          .order('COUNT(conversations.id) ASC')
                          .first
    
    # Fallback to any online support agent
    available_agents ||= User.with_role(:support).where(online: true).first
    
    # Final fallback to any support agent
    available_agents ||= User.with_role(:support).first
    
    available_agents
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
    self.last_activity_at = Time.current if will_save_change_to_any_column?
  end
end

# app/models/conversation_participant.rb (CREATE this file)
class ConversationParticipant < ApplicationRecord
  belongs_to :conversation
  belongs_to :user
  
  validates :user_id, uniqueness: { scope: :conversation_id }
  validates :role, presence: true
  
  before_create :set_joined_at
  
  scope :agents, -> { where(role: 'agent') }
  scope :customers, -> { where(role: 'customer') }
  scope :participants, -> { where(role: 'participant') }
  
  def unread_messages_count
    conversation.messages
               .where('created_at > ?', last_read_at || joined_at)
               .where.not(user: user)
               .count
  end
  
  def mark_as_read!
    update!(last_read_at: Time.current)
  end
  
  private
  
  def set_joined_at
    self.joined_at ||= Time.current
  end
end

# app/models/message.rb (CREATE this file)
class Message < ApplicationRecord
  belongs_to :conversation
  belongs_to :user
  
  enum message_type: {
    text: 0,
    voice: 1,
    image: 2,
    file: 3,
    system: 4
  }
  
  validates :content, presence: true
  validates :message_type, presence: true
  
  scope :chronological, -> { order(:created_at) }
  scope :recent, -> { order(created_at: :desc) }
  scope :user_messages, -> { where(is_system: false) }
  scope :system_messages, -> { where(is_system: true) }
  
  after_create :update_conversation_activity
  after_create_commit :broadcast_message
  
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
end