class User < ApplicationRecord
  # Include default devise modules + JWT
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :jwt_authenticatable, jwt_revocation_strategy: Devise::JWT::RevocationStrategies::Null

  # ActiveStorage for avatar
  has_one_attached :avatar

  # Business relationships
  has_many :owned_businesses, class_name: "Business", foreign_key: "owner_id"
  has_many :user_businesses
  has_many :businesses, through: :user_businesses

  # Package delivery system relationships
  has_many :packages, dependent: :destroy

  # Messaging system relationships
  has_many :conversation_participants, dependent: :destroy
  has_many :conversations, through: :conversation_participants
  has_many :messages, dependent: :destroy

  # Rolify for roles
  rolify

  # Default role after creation
  after_create :assign_default_role

  # Messaging system methods
  def mark_online!
    update!(online: true, last_seen_at: Time.current)
  end

  def mark_offline!
    update!(online: false, last_seen_at: Time.current)
  end

  def support_conversations
    conversations.where(conversation_type: 'support_ticket')
  end

  def direct_conversations
    conversations.where(conversation_type: 'direct_message')
  end

  def active_support_tickets_count
    conversation_participants.joins(:conversation)
                            .where(conversations: { conversation_type: 'support_ticket' })
                            .where(role: 'agent')
                            .where("conversations.metadata->>'status' IN (?)", ['assigned', 'in_progress', 'waiting_customer'])
                            .count
  end

  def full_name
    "#{first_name} #{last_name}".strip
  end

  def display_name
    full_name.present? ? full_name : email.split('@').first
  end

  # Role compatibility methods for messaging system
  def support_agent?
    has_role?(:support)
  end

  def client?
    has_role?(:client)
  end

  def admin?
    has_role?(:admin)
  end

  # For messaging system compatibility
  def customer?
    client? # Maps client role to customer for support system
  end

  # Package delivery related methods
  def pending_packages_count
    packages.where(state: ['pending_unpaid', 'pending']).count
  end

  def active_packages_count
    packages.where(state: ['submitted', 'in_transit']).count
  end

  def delivered_packages_count
    packages.where(state: 'delivered').count
  end

  private

  def assign_default_role
    add_role(:client) if roles.blank?
  end
end