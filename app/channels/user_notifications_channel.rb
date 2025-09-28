# app/channels/user_notifications_channel.rb
class UserNotificationsChannel < ApplicationCable::Channel
  def subscribed
    # Stream from multiple channels for comprehensive real-time updates
    stream_from "user_notifications_#{current_user.id}"
    stream_from "user_cart_#{current_user.id}"
    stream_from "user_messages_#{current_user.id}"
    stream_from "user_packages_#{current_user.id}"
    
    Rails.logger.info "User #{current_user.id} subscribed to all real-time updates"
    
    # Send initial counts immediately upon connection
    send_initial_counts
  end

  def unsubscribed
    Rails.logger.info "User #{current_user.id} unsubscribed from real-time updates"
  end

  # Client can request fresh counts manually
  def request_counts
    send_initial_counts
  end

  # Handle message read status updates
  def mark_message_read(data)
    begin
      conversation_id = data['conversation_id']
      conversation = current_user.conversations.find(conversation_id)
      conversation.mark_read_by(current_user)
      
      # Broadcast updated unread message count
      broadcast_message_counts
      
      transmit({
        type: 'message_read_success',
        conversation_id: conversation_id
      })
    rescue => e
      Rails.logger.error "Failed to mark message as read: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to mark message as read'
      })
    end
  end

  # Handle notification read status updates
  def mark_notification_read(data)
    begin
      notification_id = data['notification_id']
      notification = current_user.notifications.find(notification_id)
      notification.mark_as_read!
      
      # Broadcast updated notification count
      broadcast_notification_counts
      
      transmit({
        type: 'notification_read_success',
        notification_id: notification_id
      })
    rescue => e
      Rails.logger.error "Failed to mark notification as read: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to mark notification as read'
      })
    end
  end

  private

  def send_initial_counts
    begin
      # Calculate all counts efficiently in a single query batch
      notification_count = current_user.notifications.unread.count
      cart_count = current_user.packages.where(state: 'pending_unpaid').count
      unread_messages_count = calculate_unread_messages_count
      
      # Send comprehensive initial state
      transmit({
        type: 'initial_counts',
        notification_count: notification_count,
        cart_count: cart_count,
        unread_messages_count: unread_messages_count,
        timestamp: Time.current.iso8601,
        user_id: current_user.id
      })
      
      Rails.logger.info "Initial counts sent to user #{current_user.id}: notifications=#{notification_count}, cart=#{cart_count}, messages=#{unread_messages_count}"
    rescue => e
      Rails.logger.error "Failed to send initial counts: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to load initial counts'
      })
    end
  end

  def broadcast_notification_counts
    notification_count = current_user.notifications.unread.count
    
    ActionCable.server.broadcast(
      "user_notifications_#{current_user.id}",
      {
        type: 'notification_count_update',
        notification_count: notification_count,
        timestamp: Time.current.iso8601
      }
    )
  end

  def broadcast_message_counts
    unread_messages_count = calculate_unread_messages_count
    
    ActionCable.server.broadcast(
      "user_messages_#{current_user.id}",
      {
        type: 'message_count_update',
        unread_messages_count: unread_messages_count,
        timestamp: Time.current.iso8601
      }
    )
  end

  def broadcast_cart_counts
    cart_count = current_user.packages.where(state: 'pending_unpaid').count
    
    ActionCable.server.broadcast(
      "user_cart_#{current_user.id}",
      {
        type: 'cart_count_update',
        cart_count: cart_count,
        timestamp: Time.current.iso8601
      }
    )
  end

  def calculate_unread_messages_count
    # Calculate unread messages across all conversations
    unread_count = 0
    
    current_user.conversations.includes(:messages).each do |conversation|
      last_read_at = conversation.last_read_at_for(current_user)
      
      if last_read_at
        unread_count += conversation.messages.where('created_at > ?', last_read_at).count
      else
        unread_count += conversation.messages.count
      end
    end
    
    unread_count
  rescue => e
    Rails.logger.error "Failed to calculate unread messages: #{e.message}"
    0
  end
end