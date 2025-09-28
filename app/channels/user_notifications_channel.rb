# app/channels/user_notifications_channel.rb - Fixed with proper message broadcasting integration

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

  # FIXED: Enhanced message read status updates with proper broadcasting
  def mark_message_read(data)
    begin
      conversation_id = data['conversation_id']
      conversation = current_user.conversations.find(conversation_id)
      
      # Mark conversation as read
      conversation.mark_read_by(current_user)
      
      # Broadcast updated unread message count to user
      broadcast_message_counts
      
      # FIXED: Broadcast read status to all conversation participants
      ActionCable.server.broadcast(
        "conversation_#{conversation_id}",
        {
          type: 'conversation_read',
          user_id: current_user.id,
          user_name: current_user.display_name || current_user.email,
          reader_name: current_user.display_name || current_user.email,
          conversation_id: conversation_id,
          timestamp: Time.current.iso8601
        }
      )
      
      # Send success response back to client
      transmit({
        type: 'message_read_success',
        conversation_id: conversation_id,
        timestamp: Time.current.iso8601
      })
      
      Rails.logger.info "User #{current_user.id} marked conversation #{conversation_id} as read"
      
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Conversation not found for mark_message_read: #{e.message}"
      transmit({
        type: 'error',
        message: 'Conversation not found',
        error_code: 'CONVERSATION_NOT_FOUND'
      })
    rescue => e
      Rails.logger.error "Failed to mark message as read: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to mark message as read',
        error_code: 'MARK_READ_FAILED'
      })
    end
  end

  # FIXED: Enhanced notification read status updates
  def mark_notification_read(data)
    begin
      notification_id = data['notification_id']
      notification = current_user.notifications.find(notification_id)
      
      # Mark notification as read
      notification.mark_as_read!
      
      # Broadcast updated notification count
      broadcast_notification_counts
      
      # Send success response
      transmit({
        type: 'notification_read_success',
        notification_id: notification_id,
        timestamp: Time.current.iso8601
      })
      
      Rails.logger.info "User #{current_user.id} marked notification #{notification_id} as read"
      
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Notification not found for mark_notification_read: #{e.message}"
      transmit({
        type: 'error',
        message: 'Notification not found',
        error_code: 'NOTIFICATION_NOT_FOUND'
      })
    rescue => e
      Rails.logger.error "Failed to mark notification as read: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to mark notification as read',
        error_code: 'MARK_NOTIFICATION_READ_FAILED'
      })
    end
  end

  # FIXED: Enhanced typing indicators with proper error handling
  def typing_indicator(data)
    begin
      conversation_id = data['conversation_id']
      typing = data['typing'] == true
      
      # Verify user has access to this conversation
      conversation = current_user.conversations.find(conversation_id)
      
      # FIXED: Broadcast typing status to other conversation participants with proper format
      ActionCable.server.broadcast(
        "conversation_#{conversation_id}",
        {
          type: 'typing_indicator',
          user_id: current_user.id,
          user_name: current_user.display_name || current_user.email || 'Unknown User',
          conversation_id: conversation_id,
          typing: typing,
          timestamp: Time.current.iso8601
        }
      )
      
      # Send confirmation back to client
      transmit({
        type: 'typing_indicator_sent',
        conversation_id: conversation_id,
        typing: typing
      })
      
      Rails.logger.info "Typing indicator broadcast for user #{current_user.id} in conversation #{conversation_id}: #{typing}"
      
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Conversation not found for typing indicator: #{e.message}"
      transmit({
        type: 'error',
        message: 'Conversation not found',
        error_code: 'CONVERSATION_NOT_FOUND'
      })
    rescue => e
      Rails.logger.error "Failed to broadcast typing indicator: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to update typing status',
        error_code: 'TYPING_INDICATOR_FAILED'
      })
    end
  end

  # FIXED: Enhanced conversation joining with proper channel management
  def join_conversation(data)
    begin
      conversation_id = data['conversation_id']
      conversation = current_user.conversations.find(conversation_id)
      
      # Subscribe to conversation-specific channel
      stream_from "conversation_#{conversation_id}"
      
      # FIXED: Broadcast user joined to other participants with enhanced data
      ActionCable.server.broadcast(
        "conversation_#{conversation_id}",
        {
          type: 'user_joined_conversation',
          user_id: current_user.id,
          user_name: current_user.display_name || current_user.email || 'Unknown User',
          conversation_id: conversation_id,
          timestamp: Time.current.iso8601
        }
      )
      
      # Send success confirmation
      transmit({
        type: 'conversation_joined',
        conversation_id: conversation_id,
        user_id: current_user.id,
        timestamp: Time.current.iso8601
      })
      
      Rails.logger.info "User #{current_user.id} joined conversation #{conversation_id}"
      
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Conversation not found for join: #{e.message}"
      transmit({
        type: 'error',
        message: 'Conversation not found or access denied',
        error_code: 'CONVERSATION_ACCESS_DENIED'
      })
    rescue => e
      Rails.logger.error "Failed to join conversation: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to join conversation',
        error_code: 'JOIN_CONVERSATION_FAILED'
      })
    end
  end

  # FIXED: Enhanced conversation leaving with proper cleanup
  def leave_conversation(data)
    begin
      conversation_id = data['conversation_id']
      
      # FIXED: Broadcast user left to other participants before unsubscribing
      ActionCable.server.broadcast(
        "conversation_#{conversation_id}",
        {
          type: 'user_left_conversation',
          user_id: current_user.id,
          user_name: current_user.display_name || current_user.email || 'Unknown User',
          conversation_id: conversation_id,
          timestamp: Time.current.iso8601
        }
      )
      
      # Stop streaming from conversation channel
      stop_stream_from "conversation_#{conversation_id}"
      
      # Send success confirmation
      transmit({
        type: 'conversation_left',
        conversation_id: conversation_id,
        user_id: current_user.id,
        timestamp: Time.current.iso8601
      })
      
      Rails.logger.info "User #{current_user.id} left conversation #{conversation_id}"
      
    rescue => e
      Rails.logger.error "Failed to leave conversation: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to leave conversation',
        error_code: 'LEAVE_CONVERSATION_FAILED'
      })
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
          business_id: business_id,
          business_name: business.name,
          timestamp: Time.current.iso8601
        })
        
        Rails.logger.info "User #{current_user.id} subscribed to business #{business_id} updates"
      else
        transmit({
          type: 'error',
          message: 'Access denied to business updates',
          error_code: 'BUSINESS_ACCESS_DENIED'
        })
      end
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Business not found: #{e.message}"
      transmit({
        type: 'error',
        message: 'Business not found',
        error_code: 'BUSINESS_NOT_FOUND'
      })
    rescue => e
      Rails.logger.error "Failed to subscribe to business updates: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to subscribe to business updates',
        error_code: 'BUSINESS_SUBSCRIPTION_FAILED'
      })
    end
  end

  # FIXED: Enhanced presence updates with better broadcasting
  def update_presence(data)
    begin
      status = data['status'] || 'online'
      
      # Update user's last seen timestamp
      if current_user.respond_to?(:last_seen_at)
        current_user.update_column(:last_seen_at, Time.current)
      end
      
      # Broadcast presence to relevant channels
      broadcast_presence_update(status)
      
      # Send confirmation
      transmit({
        type: 'presence_updated',
        status: status,
        user_id: current_user.id,
        timestamp: Time.current.iso8601
      })
      
      Rails.logger.info "User #{current_user.id} presence updated to: #{status}"
      
    rescue => e
      Rails.logger.error "Failed to update presence: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to update presence',
        error_code: 'PRESENCE_UPDATE_FAILED'
      })
    end
  end

  private

  # FIXED: Enhanced initial state with better error handling and formatting
  def send_initial_state
    begin
      # Calculate all counts efficiently with error handling
      notification_count = safe_count { current_user.notifications.unread.count }
      cart_count = calculate_cart_count
      unread_messages_count = calculate_unread_messages_count
      
      # Get recent conversations for quick access
      recent_conversations = get_recent_conversations
      
      # Get business information
      business_info = get_user_businesses_info
      
      # FIXED: Send comprehensive initial state with proper formatting
      transmit({
        type: 'initial_state',
        counts: {
          notifications: notification_count,
          cart: cart_count,
          unread_messages: unread_messages_count
        },
        user: {
          id: current_user.id,
          name: current_user.display_name || current_user.email || 'Unknown User',
          email: current_user.email,
          avatar_url: get_avatar_url_safely(current_user),
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
        message: 'Failed to load initial state',
        error_code: 'INITIAL_STATE_FAILED',
        timestamp: Time.current.iso8601
      })
    end
  end

  # FIXED: Enhanced initial counts with better error handling
  def send_initial_counts
    begin
      notification_count = safe_count { current_user.notifications.unread.count }
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
      
      Rails.logger.info "Initial counts sent to user #{current_user.id}: notifications=#{notification_count}, cart=#{cart_count}, messages=#{unread_messages_count}"
      
    rescue => e
      Rails.logger.error "Failed to send initial counts: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to load initial counts',
        error_code: 'INITIAL_COUNTS_FAILED',
        timestamp: Time.current.iso8601
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
      
      # FIXED: Subscribe to user's active conversations with better error handling
      if current_user.respond_to?(:conversations)
        active_conversation_ids = current_user.conversations
                                             .where("metadata->>'status' IN (?)", ['pending', 'in_progress'])
                                             .pluck(:id)
        
        active_conversation_ids.each do |conversation_id|
          stream_from "conversation_#{conversation_id}"
        end
        
        Rails.logger.info "User #{current_user.id} subscribed to #{active_conversation_ids.count} active conversations"
      end
      
    rescue => e
      Rails.logger.error "Failed to subscribe to support channels: #{e.message}"
    end
  end

  # FIXED: Enhanced notification count broadcasting
  def broadcast_notification_counts
    begin
      notification_count = safe_count { current_user.notifications.unread.count }
      
      ActionCable.server.broadcast(
        "user_notifications_#{current_user.id}",
        {
          type: 'notification_count_update',
          notification_count: notification_count,
          user_id: current_user.id,
          timestamp: Time.current.iso8601
        }
      )
      
      Rails.logger.debug "Broadcasted notification count update: #{notification_count}"
      
    rescue => e
      Rails.logger.error "Failed to broadcast notification counts: #{e.message}"
    end
  end

  # FIXED: Enhanced message count broadcasting
  def broadcast_message_counts
    begin
      unread_messages_count = calculate_unread_messages_count
      
      ActionCable.server.broadcast(
        "user_messages_#{current_user.id}",
        {
          type: 'message_count_update',
          unread_messages_count: unread_messages_count,
          user_id: current_user.id,
          timestamp: Time.current.iso8601
        }
      )
      
      Rails.logger.debug "Broadcasted message count update: #{unread_messages_count}"
      
    rescue => e
      Rails.logger.error "Failed to broadcast message counts: #{e.message}"
    end
  end

  def broadcast_cart_counts
    begin
      cart_count = calculate_cart_count
      
      ActionCable.server.broadcast(
        "user_cart_#{current_user.id}",
        {
          type: 'cart_count_update',
          cart_count: cart_count,
          user_id: current_user.id,
          timestamp: Time.current.iso8601
        }
      )
      
      Rails.logger.debug "Broadcasted cart count update: #{cart_count}"
      
    rescue => e
      Rails.logger.error "Failed to broadcast cart counts: #{e.message}"
    end
  end

  # FIXED: Enhanced presence broadcasting with better error handling
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
            user_name: current_user.display_name || current_user.email || 'Unknown User',
            status: status,
            timestamp: Time.current.iso8601
          }
        )
      end
      
      # Broadcast to active conversations
      if current_user.respond_to?(:conversations)
        active_conversation_ids = current_user.conversations.where(
          "metadata->>'status' IN (?)", ['pending', 'in_progress']
        ).pluck(:id)
        
        active_conversation_ids.each do |conversation_id|
          ActionCable.server.broadcast(
            "conversation_#{conversation_id}",
            {
              type: 'user_presence_updated',
              user_id: current_user.id,
              user_name: current_user.display_name || current_user.email || 'Unknown User',
              status: status,
              timestamp: Time.current.iso8601
            }
          )
        end
      end
      
    rescue => e
      Rails.logger.error "Failed to broadcast presence update: #{e.message}"
    end
  end

  # FIXED: Enhanced cart count calculation with better error handling
  def calculate_cart_count
    return 0 unless current_user.respond_to?(:packages)
    
    safe_count { current_user.packages.where(state: 'pending_unpaid').count }
  rescue => e
    Rails.logger.error "Failed to calculate cart count: #{e.message}"
    0
  end

  # FIXED: Enhanced unread messages calculation with better performance
  def calculate_unread_messages_count
    return 0 unless current_user.respond_to?(:conversations)
    
    unread_count = 0
    
    # More efficient calculation using joins
    current_user.conversations.includes(:messages, :conversation_participants).each do |conversation|
      begin
        last_read_at = conversation.last_read_at_for(current_user)
        
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
    Rails.logger.error "Failed to calculate unread messages: #{e.message}"
    0
  end

  # FIXED: Enhanced recent conversations with better formatting
  def get_recent_conversations
    return [] unless current_user.respond_to?(:conversations)
    
    current_user.conversations
                .includes(:messages, :conversation_participants)
                .order(last_activity_at: :desc)
                .limit(5)
                .map do |conversation|
                  begin
                    {
                      id: conversation.id,
                      title: conversation.title || 'Untitled Conversation',
                      last_activity_at: conversation.last_activity_at&.iso8601,
                      unread_count: conversation.respond_to?(:unread_count_for) ? 
                                   conversation.unread_count_for(current_user) : 0,
                      status: conversation.respond_to?(:status) ? conversation.status : 'unknown'
                    }
                  rescue => e
                    Rails.logger.error "Error formatting conversation #{conversation.id}: #{e.message}"
                    {
                      id: conversation.id,
                      title: 'Error loading conversation',
                      error: true
                    }
                  end
                end.compact
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
            name: business.name || 'Unnamed Business',
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
            name: ub.business.name || 'Unnamed Business',
            role: ub.role || 'staff'
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

  # FIXED: Add helper methods for safer operations
  def safe_count(&block)
    block.call
  rescue => e
    Rails.logger.error "Error in count calculation: #{e.message}"
    0
  end

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
    Rails.logger.error "Error getting avatar URL: #{e.message}"
    nil
  end
end