# app/channels/user_notifications_channel.rb - Enhanced with comprehensive real-time capabilities

class UserNotificationsChannel < ApplicationCable::Channel
  def subscribed
    # Core user-specific channels
    stream_from "user_notifications_#{current_user.id}"
    stream_from "user_cart_#{current_user.id}"
    stream_from "user_messages_#{current_user.id}"
    stream_from "user_packages_#{current_user.id}"
    
    # ENHANCED: Profile and avatar update channels
    stream_from "user_profile_updates"
    stream_from "user_avatar_updates"
    
    # ENHANCED: Business-related channels
    subscribe_to_business_channels
    
    # ENHANCED: Support and conversation channels
    subscribe_to_support_channels
    
    Rails.logger.info "User #{current_user.id} subscribed to comprehensive real-time updates"
    
    # Send initial state immediately upon connection
    send_initial_state
    
    # Update user's online status
    update_user_presence(true)
  end

  def unsubscribed
    Rails.logger.info "User #{current_user.id} unsubscribed from real-time updates"
    
    # Update user's offline status
    update_user_presence(false)
  end

  # Client can request fresh counts manually
  def request_counts
    send_initial_counts
  end

  # ENHANCED: Request full initial state
  def request_initial_state
    send_initial_state
  end

  # Handle message read status updates
  def mark_message_read(data)
    begin
      conversation_id = data['conversation_id']
      conversation = current_user.conversations.find(conversation_id)
      conversation.mark_read_by(current_user)
      
      # Broadcast updated unread message count
      broadcast_message_counts
      
      # ENHANCED: Broadcast read status to conversation participants
      ActionCable.server.broadcast(
        "conversation_#{conversation_id}",
        {
          type: 'message_read_by_user',
          user_id: current_user.id,
          user_name: current_user.display_name,
          conversation_id: conversation_id,
          timestamp: Time.current.iso8601
        }
      )
      
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

  # ENHANCED: Handle typing indicators for conversations
  def typing_indicator(data)
    begin
      conversation_id = data['conversation_id']
      typing = data['typing'] == true
      
      # Verify user has access to this conversation
      conversation = current_user.conversations.find(conversation_id)
      
      # Broadcast typing status to other conversation participants
      ActionCable.server.broadcast(
        "conversation_#{conversation_id}",
        {
          type: 'typing_indicator',
          user_id: current_user.id,
          user_name: current_user.display_name,
          typing: typing,
          timestamp: Time.current.iso8601
        }
      )
      
      Rails.logger.info "Typing indicator broadcast for user #{current_user.id} in conversation #{conversation_id}: #{typing}"
    rescue => e
      Rails.logger.error "Failed to broadcast typing indicator: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to update typing status'
      })
    end
  end

  # ENHANCED: Handle conversation joining/leaving
  def join_conversation(data)
    begin
      conversation_id = data['conversation_id']
      conversation = current_user.conversations.find(conversation_id)
      
      # Subscribe to conversation-specific channel
      stream_from "conversation_#{conversation_id}"
      
      # Broadcast user joined to other participants
      ActionCable.server.broadcast(
        "conversation_#{conversation_id}",
        {
          type: 'user_joined_conversation',
          user_id: current_user.id,
          user_name: current_user.display_name,
          timestamp: Time.current.iso8601
        }
      )
      
      transmit({
        type: 'conversation_joined',
        conversation_id: conversation_id
      })
      
      Rails.logger.info "User #{current_user.id} joined conversation #{conversation_id}"
    rescue => e
      Rails.logger.error "Failed to join conversation: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to join conversation'
      })
    end
  end

  def leave_conversation(data)
    begin
      conversation_id = data['conversation_id']
      
      # Broadcast user left to other participants
      ActionCable.server.broadcast(
        "conversation_#{conversation_id}",
        {
          type: 'user_left_conversation',
          user_id: current_user.id,
          user_name: current_user.display_name,
          timestamp: Time.current.iso8601
        }
      )
      
      # Stop streaming from conversation channel
      stop_stream_from "conversation_#{conversation_id}"
      
      transmit({
        type: 'conversation_left',
        conversation_id: conversation_id
      })
      
      Rails.logger.info "User #{current_user.id} left conversation #{conversation_id}"
    rescue => e
      Rails.logger.error "Failed to leave conversation: #{e.message}"
    end
  end

  # ENHANCED: Handle business channel subscriptions
  def subscribe_to_business(data)
    begin
      business_id = data['business_id']
      
      # Verify user has access to this business
      business = get_user_business(business_id)
      if business
        stream_from "business_#{business_id}_updates"
        
        transmit({
          type: 'business_subscription_success',
          business_id: business_id
        })
        
        Rails.logger.info "User #{current_user.id} subscribed to business #{business_id} updates"
      else
        transmit({
          type: 'error',
          message: 'Access denied to business updates'
        })
      end
    rescue => e
      Rails.logger.error "Failed to subscribe to business updates: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to subscribe to business updates'
      })
    end
  end

  # ENHANCED: Handle presence updates
  def update_presence(data)
    begin
      status = data['status'] || 'online'
      
      # Update user's last seen timestamp
      current_user.update_column(:last_seen_at, Time.current) if current_user.respond_to?(:last_seen_at)
      
      # Broadcast presence to relevant channels
      broadcast_presence_update(status)
      
      transmit({
        type: 'presence_updated',
        status: status
      })
    rescue => e
      Rails.logger.error "Failed to update presence: #{e.message}"
    end
  end

  private

  # ENHANCED: Send comprehensive initial state
  def send_initial_state
    begin
      # Calculate all counts efficiently
      notification_count = current_user.notifications.unread.count
      cart_count = calculate_cart_count
      unread_messages_count = calculate_unread_messages_count
      
      # Get recent conversations for quick access
      recent_conversations = get_recent_conversations
      
      # Get business information
      business_info = get_user_businesses_info
      
      # Send comprehensive initial state
      transmit({
        type: 'initial_state',
        counts: {
          notifications: notification_count,
          cart: cart_count,
          unread_messages: unread_messages_count
        },
        user: {
          id: current_user.id,
          name: current_user.display_name,
          email: current_user.email,
          avatar_url: current_user.respond_to?(:avatar_url) ? current_user.avatar_url : nil,
          online: true
        },
        recent_conversations: recent_conversations,
        businesses: business_info,
        timestamp: Time.current.iso8601
      })
      
      Rails.logger.info "Initial state sent to user #{current_user.id}: notifications=#{notification_count}, cart=#{cart_count}, messages=#{unread_messages_count}"
    rescue => e
      Rails.logger.error "Failed to send initial state: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to load initial state'
      })
    end
  end

  # ENHANCED: Send just the counts (backward compatibility)
  def send_initial_counts
    begin
      notification_count = current_user.notifications.unread.count
      cart_count = calculate_cart_count
      unread_messages_count = calculate_unread_messages_count
      
      transmit({
        type: 'initial_counts',
        notification_count: notification_count,
        cart_count: cart_count,
        unread_messages_count: unread_messages_count,
        timestamp: Time.current.iso8601,
        user_id: current_user.id
      })
      
      Rails.logger.info "Initial counts sent to user #{current_user.id}"
    rescue => e
      Rails.logger.error "Failed to send initial counts: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to load initial counts'
      })
    end
  end

  def subscribe_to_business_channels
    begin
      # Subscribe to all businesses where user is owner or staff
      business_ids = []
      
      # Add owned businesses
      if current_user.respond_to?(:owned_businesses)
        business_ids += current_user.owned_businesses.pluck(:id)
      end
      
      # Add businesses where user is staff
      if current_user.respond_to?(:user_businesses)
        business_ids += current_user.user_businesses.pluck(:business_id)
      end
      
      # Subscribe to each business channel
      business_ids.uniq.each do |business_id|
        stream_from "business_#{business_id}_updates"
      end
      
      # Also subscribe to personal business updates
      stream_from "user_businesses_#{current_user.id}"
      
      Rails.logger.info "User #{current_user.id} subscribed to #{business_ids.count} business channels"
    rescue => e
      Rails.logger.error "Failed to subscribe to business channels: #{e.message}"
    end
  end

  def subscribe_to_support_channels
    begin
      # Subscribe to support tickets if user is support staff
      if is_support_user?
        stream_from "support_tickets"
        Rails.logger.info "User #{current_user.id} subscribed to support tickets channel"
      end
      
      # Subscribe to user's active conversations
      active_conversation_ids = current_user.conversations
                                           .where("metadata->>'status' IN (?)", ['pending', 'in_progress'])
                                           .pluck(:id)
      
      active_conversation_ids.each do |conversation_id|
        stream_from "conversation_#{conversation_id}"
      end
      
      Rails.logger.info "User #{current_user.id} subscribed to #{active_conversation_ids.count} active conversations"
    rescue => e
      Rails.logger.error "Failed to subscribe to support channels: #{e.message}"
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
    cart_count = calculate_cart_count
    
    ActionCable.server.broadcast(
      "user_cart_#{current_user.id}",
      {
        type: 'cart_count_update',
        cart_count: cart_count,
        timestamp: Time.current.iso8601
      }
    )
  end

  def broadcast_presence_update(status)
    begin
      # Broadcast to businesses where user is involved
      business_ids = get_user_business_ids
      
      business_ids.each do |business_id|
        ActionCable.server.broadcast(
          "business_#{business_id}_updates",
          {
            type: 'member_presence_updated',
            user_id: current_user.id,
            user_name: current_user.display_name,
            status: status,
            timestamp: Time.current.iso8601
          }
        )
      end
      
      # Broadcast to active conversations
      active_conversation_ids = current_user.conversations.where(
        "metadata->>'status' IN (?)", ['pending', 'in_progress']
      ).pluck(:id)
      
      active_conversation_ids.each do |conversation_id|
        ActionCable.server.broadcast(
          "conversation_#{conversation_id}",
          {
            type: 'user_presence_updated',
            user_id: current_user.id,
            user_name: current_user.display_name,
            status: status,
            timestamp: Time.current.iso8601
          }
        )
      end
    rescue => e
      Rails.logger.error "Failed to broadcast presence update: #{e.message}"
    end
  end

  def calculate_cart_count
    if current_user.respond_to?(:packages)
      current_user.packages.where(state: 'pending_unpaid').count
    else
      0
    end
  rescue => e
    Rails.logger.error "Failed to calculate cart count: #{e.message}"
    0
  end

  def calculate_unread_messages_count
    unread_count = 0
    
    return 0 unless current_user.respond_to?(:conversations)
    
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

  def get_recent_conversations
    return [] unless current_user.respond_to?(:conversations)
    
    current_user.conversations
                .includes(:messages, :conversation_participants)
                .order(last_activity_at: :desc)
                .limit(5)
                .map do |conversation|
                  {
                    id: conversation.id,
                    title: conversation.title,
                    last_activity_at: conversation.last_activity_at&.iso8601,
                    unread_count: conversation.unread_count_for(current_user)
                  }
                end
  rescue => e
    Rails.logger.error "Failed to get recent conversations: #{e.message}"
    []
  end

  def get_user_businesses_info
    businesses = []
    
    begin
      # Add owned businesses
      if current_user.respond_to?(:owned_businesses)
        owned = current_user.owned_businesses.limit(10).map do |business|
          {
            id: business.id,
            name: business.name,
            role: 'owner'
          }
        end
        businesses += owned
      end
      
      # Add businesses where user is staff
      if current_user.respond_to?(:user_businesses)
        staff = current_user.user_businesses.includes(:business).limit(10).map do |ub|
          {
            id: ub.business.id,
            name: ub.business.name,
            role: ub.role
          }
        end
        businesses += staff
      end
    rescue => e
      Rails.logger.error "Failed to get user businesses info: #{e.message}"
    end
    
    businesses
  end

  def get_user_business(business_id)
    # Check if user owns the business
    if current_user.respond_to?(:owned_businesses)
      business = current_user.owned_businesses.find_by(id: business_id)
      return business if business
    end
    
    # Check if user is staff
    if current_user.respond_to?(:user_businesses)
      user_business = current_user.user_businesses.find_by(business_id: business_id)
      return user_business&.business
    end
    
    nil
  end

  def get_user_business_ids
    business_ids = []
    
    begin
      if current_user.respond_to?(:owned_businesses)
        business_ids += current_user.owned_businesses.pluck(:id)
      end
      
      if current_user.respond_to?(:user_businesses)
        business_ids += current_user.user_businesses.pluck(:business_id)
      end
    rescue => e
      Rails.logger.error "Failed to get user business IDs: #{e.message}"
    end
    
    business_ids.uniq
  end

  def is_support_user?
    # Check multiple methods to determine if user is support staff
    return true if current_user.respond_to?(:support_agent?) && current_user.support_agent?
    return true if current_user.respond_to?(:admin?) && current_user.admin?
    return true if current_user.email&.include?('@glt.co.ke')
    return true if current_user.email&.include?('support@')
    
    false
  rescue => e
    Rails.logger.error "Failed to check support user status: #{e.message}"
    false
  end

  def update_user_presence(online)
    begin
      if current_user.respond_to?(:update_presence)
        current_user.update_presence(online)
      elsif current_user.respond_to?(:last_seen_at)
        current_user.update_column(:last_seen_at, Time.current) if online
      end
    rescue => e
      Rails.logger.error "Failed to update user presence: #{e.message}"
    end
  end
end