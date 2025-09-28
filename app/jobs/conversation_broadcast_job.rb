class ConversationBroadcastJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, message_id)
    Rails.logger.info "🔍 ConversationBroadcastJob STARTED: conv=#{conversation_id}, msg=#{message_id}"
    
    begin
      conversation = Conversation.find(conversation_id)
      message = Message.find(message_id)
      
      Rails.logger.info "✅ Records FOUND: conv=#{conversation.id}, msg=#{message.id}"
      
      # ENHANCED: Get message sender information
      sender = message.user
      sender_data = {
        id: sender.id,
        name: sender.display_name || sender.email || 'Unknown User',
        role: message.from_support? ? 'support' : 'customer',
        avatar_url: get_avatar_url_safely(sender)
      }
      
      # ENHANCED: Get conversation metadata
      conversation_data = {
        id: conversation.id,
        title: conversation.title,
        type: conversation.conversation_type,
        status: conversation.respond_to?(:status) ? conversation.status : 'active',
        last_activity_at: conversation.last_activity_at&.iso8601
      }
      
      # ENHANCED: Prepare comprehensive message payload
      message_payload = {
        id: message.id,
        content: message.content,
        message_type: message.message_type || 'text',
        created_at: message.created_at.iso8601,
        timestamp: message.created_at.strftime('%H:%M'),
        from_support: message.from_support?,
        is_system: message.message_type == 'system',
        user: sender_data,
        metadata: message.metadata || {}
      }
      
      # Main broadcast to conversation channel
      channel_name = "conversation_#{conversation_id}"
      payload = {
        type: 'new_message',
        conversation_id: conversation_id,
        message: message_payload,
        conversation: conversation_data,
        timestamp: Time.current.iso8601
      }
      
      Rails.logger.info "📡 BROADCASTING to #{channel_name}"
      ActionCable.server.broadcast(channel_name, payload)
      
      # ENHANCED: Broadcast to individual user message channels for notifications
      broadcast_to_individual_users(conversation, message, message_payload)
      
      # ENHANCED: Update conversation's last activity
      update_conversation_activity(conversation, message)
      
      Rails.logger.info "✅ BROADCAST COMPLETED for conversation #{conversation_id}"
      
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "❌ ConversationBroadcastJob RECORD NOT FOUND: #{e.message}"
      raise e
    rescue => e
      Rails.logger.error "❌ ConversationBroadcastJob FAILED: #{e.message}"
      Rails.logger.error "📍 Backtrace: #{e.backtrace.first(5)}"
      raise e
    end
  end

  private

  # ENHANCED: Broadcast to individual users for proper notification handling
  def broadcast_to_individual_users(conversation, message, message_payload)
    begin
      # Get all conversation participants except the sender
      participants = conversation.conversation_participants
                                .includes(:user)
                                .where.not(user_id: message.user_id)
      
      participants.each do |participant|
        user = participant.user
        next unless user
        
        # Calculate if this creates an unread message for this user
        last_read_at = conversation.last_read_at_for(user)
        is_unread = last_read_at.nil? || message.created_at > last_read_at
        
        if is_unread
          # Broadcast unread message count update
          broadcast_unread_count_update(user)
          
          # Broadcast to user's personal message channel
          ActionCable.server.broadcast(
            "user_messages_#{user.id}",
            {
              type: 'new_message_notification',
              conversation_id: conversation.id,
              message: message_payload,
              sender_name: message.user.display_name || message.user.email || 'Unknown User',
              preview: truncate_message_content(message.content),
              timestamp: Time.current.iso8601
            }
          )
          
          Rails.logger.debug "📡 Broadcasted message notification to user #{user.id}"
        end
      end
      
    rescue => e
      Rails.logger.error "❌ Failed to broadcast to individual users: #{e.message}"
    end
  end

  # ENHANCED: Broadcast updated unread message count to user
  def broadcast_unread_count_update(user)
    begin
      # Calculate total unread messages for user
      unread_count = calculate_unread_messages_for_user(user)
      
      ActionCable.server.broadcast(
        "user_messages_#{user.id}",
        {
          type: 'message_count_update',
          unread_messages_count: unread_count,
          user_id: user.id,
          timestamp: Time.current.iso8601
        }
      )
      
      Rails.logger.debug "📡 Updated unread count for user #{user.id}: #{unread_count}"
      
    rescue => e
      Rails.logger.error "❌ Failed to broadcast unread count update: #{e.message}"
    end
  end

  # ENHANCED: Calculate unread messages for a specific user
  def calculate_unread_messages_for_user(user)
    return 0 unless user.respond_to?(:conversations)
    
    unread_count = 0
    
    user.conversations.includes(:messages, :conversation_participants).find_each do |conversation|
      begin
        last_read_at = conversation.last_read_at_for(user)
        
        if last_read_at
          unread_count += conversation.messages.where('created_at > ?', last_read_at).count
        else
          unread_count += conversation.messages.count
        end
      rescue => e
        Rails.logger.error "Error calculating unread for conversation #{conversation.id}: #{e.message}"
      end
    end
    
    unread_count
  rescue => e
    Rails.logger.error "Failed to calculate unread messages for user #{user.id}: #{e.message}"
    0
  end

  # ENHANCED: Update conversation's last activity timestamp
  def update_conversation_activity(conversation, message)
    begin
      # Update last_activity_at if the conversation supports it
      if conversation.respond_to?(:last_activity_at=)
        conversation.update_column(:last_activity_at, message.created_at)
      end
      
      # Update any related ticket timestamps if this is a support conversation
      if conversation.respond_to?(:ticket) && conversation.ticket
        ticket = conversation.ticket
        if ticket.respond_to?(:updated_at=)
          ticket.touch # Update the updated_at timestamp
        end
      end
      
    rescue => e
      Rails.logger.error "❌ Failed to update conversation activity: #{e.message}"
    end
  end

  # Helper method to safely get avatar URL
  def get_avatar_url_safely(user)
    return nil unless user
    
    if user.respond_to?(:avatar_url)
      user.avatar_url
    elsif user.respond_to?(:avatar) && user.avatar.respond_to?(:url)
      user.avatar.url
    else
      nil
    end
  rescue => e
    Rails.logger.error "Error getting avatar URL for user #{user.id}: #{e.message}"
    nil
  end

  # Helper method to truncate message content for preview
  def truncate_message_content(content, limit = 100)
    return '' if content.blank?
    
    if content.length > limit
      "#{content.first(limit).strip}..."
    else
      content.strip
    end
  end
end