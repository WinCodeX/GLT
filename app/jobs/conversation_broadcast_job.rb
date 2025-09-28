class ConversationBroadcastJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, message_id)
    conversation = Conversation.find(conversation_id)
    message = Message.find(message_id)
    
    # Broadcast to ActionCable channels
    ActionCable.server.broadcast(
      "conversation_#{conversation_id}",
      {
        type: 'new_message',
        conversation_id: conversation_id,
        message: {
          id: message.id,
          content: message.content,
          created_at: message.created_at,
          from_support: message.from_support?,
          user: {
            id: message.user.id,
            name: message.user.display_name,
            role: message.from_support? ? 'support' : 'customer'
          }
        }
      }
    )
  end
end