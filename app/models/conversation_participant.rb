# Create this file: app/models/conversation_participant.rb
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