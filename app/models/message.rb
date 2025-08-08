# app/models/message.rb
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