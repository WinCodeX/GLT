# app/channels/user_notifications_channel.rb - FIXED: Message read broadcast with individual acknowledgments

class UserNotificationsChannel < ApplicationCable::Channel
  def subscribed
    stream_from "user_notifications_#{current_user.id}"
    stream_from "user_cart_#{current_user.id}"
    stream_from "user_messages_#{current_user.id}"
    stream_from "user_packages_#{current_user.id}"
    stream_from "user_profile_updates"
    stream_from "user_avatar_updates"
    stream_from "app_updates"
    
    subscribe_to_business_channels
    subscribe_to_support_channels
    
    Rails.logger.info "User #{current_user.id} subscribed to comprehensive real-time updates"
    
    update_user_presence_status('online')
    send_initial_state
    broadcast_presence_to_relevant_channels('online')
    
    retry_undelivered_messages_to_user
  end

  def unsubscribed
    Rails.logger.info "User #{current_user.id} unsubscribed from real-time updates"
    
    update_user_presence_status('offline')
    broadcast_presence_to_relevant_channels('offline')
  end

  def update_presence(data)
    begin
      status = data['status'] || 'online'
      device_info = data['device_info'] || {}
      app_state = data['app_state'] || 'active'
      
      Rails.logger.info "User #{current_user.id} presence update: #{status} (app_state: #{app_state})"
      
      effective_status = case app_state
      when 'background', 'inactive'
        'away'
      when 'active'
        status == 'offline' ? 'online' : status
      else
        status
      end
      
      update_user_presence_status(effective_status, device_info)
      broadcast_presence_to_relevant_channels(effective_status)
      
      transmit({
        type: 'presence_updated',
        status: effective_status,
        user_id: current_user.id,
        timestamp: Time.current.iso8601
      })
      
    rescue => e
      Rails.logger.error "Failed to update presence: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to update presence',
        error_code: 'PRESENCE_UPDATE_FAILED'
      })
    end
  end

  def ping(data)
    transmit({
      type: 'pong',
      server_time: Time.current.iso8601,
      user_id: current_user.id
    })
  end

  def request_counts
    send_initial_counts
  end

  def request_initial_state
    send_initial_state
  end

  def get_user_presence(data)
    begin
      user_ids = data['user_ids'] || []
      
      if user_ids.empty?
        transmit({
          type: 'error',
          message: 'No user IDs provided',
          error_code: 'INVALID_REQUEST'
        })
        return
      end
      
      user_ids = user_ids.first(50)
      presence_data = get_users_presence_data(user_ids)
      
      transmit({
        type: 'users_presence_data',
        presence_data: presence_data,
        timestamp: Time.current.iso8601
      })
      
    rescue => e
      Rails.logger.error "Failed to get user presence: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to get user presence',
        error_code: 'GET_PRESENCE_FAILED'
      })
    end
  end

  def acknowledge_message(data)
    begin
      message_id = data['message_id']
      status = data['status']
      
      unless ['delivered', 'read'].include?(status)
        transmit({
          type: 'error',
          message: 'Invalid status. Must be delivered or read',
          error_code: 'INVALID_STATUS'
        })
        return
      end
      
      message = Message.find_by(id: message_id)
      unless message
        transmit({
          type: 'error',
          message: 'Message not found',
          error_code: 'MESSAGE_NOT_FOUND'
        })
        return
      end
      
      if status == 'delivered' && message.delivered_at.nil?
        message.update_column(:delivered_at, Time.current)
      elsif status == 'read' && message.read_at.nil?
        message.update_columns(
          delivered_at: message.delivered_at || Time.current,
          read_at: Time.current
        )
      end
      
      ActionCable.server.broadcast(
        "conversation_#{message.conversation_id}",
        {
          type: 'message_acknowledged',
          message_id: message_id.to_s,
          conversation_id: message.conversation_id.to_s,
          status: status,
          acknowledged_by: current_user.id,
          timestamp: Time.current.iso8601
        }
      )
      
      transmit({
        type: 'acknowledge_success',
        message_id: message_id,
        status: status,
        timestamp: Time.current.iso8601
      })
      
    rescue => e
      Rails.logger.error "Failed to acknowledge message: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to acknowledge message',
        error_code: 'ACKNOWLEDGE_FAILED'
      })
    end
  end

  # CRITICAL FIX: Broadcast individual message acknowledgments
  def mark_message_read(data)
    begin
      conversation_id = data['conversation_id']
      conversation = current_user.conversations.find(conversation_id)
      
      # Get unread messages and their IDs BEFORE updating
      unread_messages = conversation.messages.where(read_at: nil).where.not(user_id: current_user.id)
      unread_message_ids = unread_messages.pluck(:id)
      
      now = Time.current
      
      # Update all unread messages
      unread_messages.update_all(
        delivered_at: now,
        read_at: now
      )
      
      conversation.mark_read_by(current_user) if conversation.respond_to?(:mark_read_by)
      broadcast_message_counts
      
      # Broadcast conversation_read (for overall conversation status)
      ActionCable.server.broadcast(
        "conversation_#{conversation_id}",
        {
          type: 'conversation_read',
          user_id: current_user.id,
          user_name: current_user.display_name || current_user.email,
          reader_name: current_user.display_name || current_user.email,
          conversation_id: conversation_id.to_s,
          timestamp: now.iso8601
        }
      )
      
      # CRITICAL FIX: Broadcast individual message acknowledgments for blue ticks
      unread_message_ids.each do |message_id|
        ActionCable.server.broadcast(
          "conversation_#{conversation_id}",
          {
            type: 'message_acknowledged',
            message_id: message_id.to_s,
            conversation_id: conversation_id.to_s,
            status: 'read',
            acknowledged_by: current_user.id,
            timestamp: now.iso8601
          }
        )
      end
      
      transmit({
        type: 'message_read_success',
        conversation_id: conversation_id,
        messages_marked: unread_message_ids.size,
        timestamp: now.iso8601
      })
      
      Rails.logger.info "Marked #{unread_message_ids.size} messages as read in conversation #{conversation_id}"
      
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

  def mark_notification_read(data)
    begin
      notification_id = data['notification_id']
      notification = current_user.notifications.find(notification_id)
      
      notification.mark_as_read!
      broadcast_notification_counts
      
      transmit({
        type: 'notification_read_success',
        notification_id: notification_id,
        timestamp: Time.current.iso8601
      })
      
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Notification not found: #{e.message}"
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

  def typing_indicator(data)
    begin
      conversation_id = data['conversation_id']
      typing = data['typing'] == true
      
      conversation = current_user.conversations.find(conversation_id)
      
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
      
      transmit({
        type: 'typing_indicator_sent',
        conversation_id: conversation_id,
        typing: typing
      })
      
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

  def join_conversation(data)
    begin
      conversation_id = data['conversation_id']
      conversation = current_user.conversations.find(conversation_id)
      
      stream_from "conversation_#{conversation_id}"
      
      user_presence = get_user_presence_data(current_user.id)
      
      ActionCable.server.broadcast(
        "conversation_#{conversation_id}",
        {
          type: 'user_joined_conversation',
          user_id: current_user.id,
          user_name: current_user.display_name || current_user.email || 'Unknown User',
          user_presence: user_presence,
          conversation_id: conversation_id,
          timestamp: Time.current.iso8601
        }
      )
      
      participants_presence = get_conversation_participants_presence(conversation)
      
      transmit({
        type: 'conversation_joined',
        conversation_id: conversation_id,
        user_id: current_user.id,
        participants_presence: participants_presence,
        timestamp: Time.current.iso8601
      })
      
      Rails.logger.info "User #{current_user.id} joined conversation #{conversation_id}"
      
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Conversation not found: #{e.message}"
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

  def leave_conversation(data)
    begin
      conversation_id = data['conversation_id']
      
      ActionCable.server.broadcast(
        "conversation_#{conversation_id}",
        {
          type: 'user_left_conversation',
          user_id: current_user.id,
          user_name: current_user.display_name || current_user.email || 'Unknown User',
          conversation_id: conversation_id,
          last_seen: Time.current.iso8601,
          timestamp: Time.current.iso8601
        }
      )
      
      stop_stream_from "conversation_#{conversation_id}"
      
      transmit({
        type: 'conversation_left',
        conversation_id: conversation_id,
        user_id: current_user.id,
        timestamp: Time.current.iso8601
      })
      
    rescue => e
      Rails.logger.error "Failed to leave conversation: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to leave conversation',
        error_code: 'LEAVE_CONVERSATION_FAILED'
      })
    end
  end

  def send_message(data)
    begin
      conversation_id = data['conversation_id']
      content = data['content']
      message_type = data['message_type'] || 'text'
      metadata = data['metadata'] || {}
      temp_id = data['temp_id']
      
      conversation = current_user.conversations.find(conversation_id)
      
      message = conversation.messages.create!(
        user: current_user,
        content: content,
        message_type: message_type,
        metadata: metadata.merge(temp_id: temp_id).compact,
        sent_at: Time.current
      )
      
      if message.persisted?
        transmit({
          type: 'message_sent',
          success: true,
          message_id: message.id,
          temp_id: temp_id,
          timestamp: Time.current.iso8601
        })
        
        Rails.logger.info "Message #{message.id} created successfully"
      else
        transmit({
          type: 'error',
          message: 'Failed to send message',
          error_code: 'MESSAGE_SEND_FAILED',
          temp_id: temp_id
        })
      end
      
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Conversation not found: #{e.message}"
      transmit({
        type: 'error',
        message: 'Conversation not found',
        error_code: 'CONVERSATION_NOT_FOUND'
      })
    rescue => e
      Rails.logger.error "Failed to send message: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      transmit({
        type: 'error',
        message: 'Failed to send message',
        error_code: 'MESSAGE_SEND_FAILED'
      })
    end
  end

  def subscribe_to_business(data)
    begin
      business_id = data['business_id']
      
      business = get_user_business(business_id)
      if business
        stream_from "business_#{business_id}_updates"
        
        transmit({
          type: 'business_subscription_success',
          business_id: business_id,
          business_name: business.name,
          timestamp: Time.current.iso8601
        })
        
        Rails.logger.info "User #{current_user.id} subscribed to business #{business_id}"
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
      Rails.logger.error "Failed to subscribe to business: #{e.message}"
      transmit({
        type: 'error',
        message: 'Failed to subscribe to business updates',
        error_code: 'BUSINESS_SUBSCRIPTION_FAILED'
      })
    end
  end

  def self.broadcast_new_message(message)
    begin
      return unless message&.conversation_id
      
      conversation = message.conversation
      return unless conversation
      
      user = message.user
      return unless user
      
      message_data = {
        id: message.id.to_s,
        content: message.content,
        message_type: message.message_type || 'text',
        user_id: user.id.to_s,
        user_name: user.display_name.presence || user.name.presence || user.email.presence || 'Unknown User',
        from_support: message.from_support?,
        is_system: message.is_system?,
        created_at: message.created_at.iso8601,
        sent_at: message.sent_at&.iso8601,
        delivered_at: message.delivered_at&.iso8601,
        read_at: message.read_at&.iso8601,
        timestamp: message.created_at.strftime('%H:%M'),
        metadata: message.metadata || {},
        temp_id: message.metadata&.dig('temp_id')
      }
      
      broadcast_payload = {
        type: 'new_message',
        message: message_data,
        conversation_id: conversation.id.to_s,
        timestamp: Time.current.iso8601
      }
      
      ActionCable.server.broadcast(
        "conversation_#{conversation.id}",
        broadcast_payload
      )
      
      participant_ids = conversation.conversation_participants.pluck(:user_id)
      
      participant_ids.each do |participant_id|
        next if participant_id == user.id
        
        ActionCable.server.broadcast(
          "user_messages_#{participant_id}",
          broadcast_payload.merge(
            notification: true,
            unread: true
          )
        )
      end
      
      Rails.logger.info "Broadcasted message #{message.id} to conversation_#{conversation.id} and #{participant_ids.size} user channels"
      
    rescue => e
      Rails.logger.error "Failed to broadcast message #{message&.id}: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
    end
  end

  private

  def retry_undelivered_messages_to_user
    begin
      return unless current_user.respond_to?(:conversations)
      
      undelivered_messages = Message.joins(:conversation)
                                    .joins('INNER JOIN conversation_participants ON conversation_participants.conversation_id = conversations.id')
                                    .where('conversation_participants.user_id = ?', current_user.id)
                                    .where.not(user_id: current_user.id)
                                    .where(delivered_at: nil)
                                    .where('messages.created_at > ?', 7.days.ago)
                                    .order(created_at: :asc)
                                    .limit(100)
      
      if undelivered_messages.any?
        Rails.logger.info "Retrying #{undelivered_messages.count} undelivered messages to user #{current_user.id}"
        
        undelivered_messages.each do |message|
          begin
            message_data = format_message_for_broadcast(message)
            
            transmit({
              type: 'new_message',
              message: message_data,
              conversation_id: message.conversation_id,
              timestamp: message.created_at.iso8601,
              retry: true
            })
            
            message.update_column(:delivered_at, Time.current)
            
          rescue => e
            Rails.logger.error "Failed to retry message #{message.id}: #{e.message}"
          end
        end
        
        broadcast_message_counts
      end
      
    rescue => e
      Rails.logger.error "Failed to retry undelivered messages: #{e.message}"
    end
  end

  def format_message_for_broadcast(message)
    user = message.user
    {
      id: message.id.to_s,
      content: message.content,
      message_type: message.message_type || 'text',
      user_id: user&.id&.to_s || '',
      user_name: user&.display_name.presence || user&.name.presence || user&.email.presence || 'Unknown User',
      from_support: message.from_support?,
      is_system: message.is_system?,
      created_at: message.created_at.iso8601,
      sent_at: message.sent_at&.iso8601,
      delivered_at: message.delivered_at&.iso8601,
      read_at: message.read_at&.iso8601,
      timestamp: message.created_at.strftime('%H:%M'),
      metadata: message.metadata || {}
    }
  end

  def update_user_presence_status(status, device_info = {})
    begin
      presence_key = "user_presence:#{current_user.id}"
      presence_data = {
        status: status,
        last_seen_at: Time.current.to_i,
        device_info: device_info,
        updated_at: Time.current.to_i
      }
      
      if defined?(REDIS_POOL)
        begin
          REDIS_POOL.with do |redis|
            redis.setex(presence_key, 300, presence_data.to_json)
          end
        rescue => redis_error
          Rails.logger.error "Redis presence update failed: #{redis_error.message}"
        end
      end
      
      case status
      when 'online'
        current_user.mark_online! unless current_user.online?
      when 'offline'
        current_user.mark_offline! if current_user.online?
      when 'away', 'busy'
        current_user.mark_online! unless current_user.online?
      end
      
    rescue => e
      Rails.logger.error "Failed to update presence: #{e.message}"
    end
  end

  def get_user_presence_data(user_id)
    begin
      presence_key = "user_presence:#{user_id}"
      
      if defined?(REDIS_POOL)
        begin
          presence_json = REDIS_POOL.with do |redis|
            redis.get(presence_key)
          end
          
          if presence_json
            presence_data = JSON.parse(presence_json)
            return {
              user_id: user_id,
              status: presence_data['status'],
              last_seen_at: Time.at(presence_data['last_seen_at']).iso8601,
              is_online: presence_data['status'] == 'online',
              updated_at: Time.at(presence_data['updated_at']).iso8601
            }
          end
        rescue => redis_error
          Rails.logger.error "Redis presence fetch failed: #{redis_error.message}"
        end
      end
      
      user = User.find_by(id: user_id)
      if user
        last_seen = user.last_seen_at || user.updated_at
        
        status = if user.online?
                  'online'
                elsif last_seen && (Time.current - last_seen) < 30.minutes
                  'away'
                else
                  'offline'
                end
        
        return {
          user_id: user_id,
          status: status,
          last_seen_at: last_seen.iso8601,
          is_online: user.online?,
          updated_at: Time.current.iso8601
        }
      end
      
      {
        user_id: user_id,
        status: 'offline',
        last_seen_at: 1.hour.ago.iso8601,
        is_online: false,
        updated_at: Time.current.iso8601
      }
      
    rescue => e
      Rails.logger.error "Failed to get presence: #{e.message}"
      {
        user_id: user_id,
        status: 'offline',
        last_seen_at: 1.hour.ago.iso8601,
        is_online: false,
        updated_at: Time.current.iso8601
      }
    end
  end

  def get_users_presence_data(user_ids)
    user_ids.map { |user_id| get_user_presence_data(user_id) }
  end

  def get_conversation_participants_presence(conversation)
    begin
      participant_ids = conversation.conversation_participants
                                  .where.not(user_id: current_user.id)
                                  .pluck(:user_id)
      
      get_users_presence_data(participant_ids)
    rescue => e
      Rails.logger.error "Failed to get participants presence: #{e.message}"
      []
    end
  end

  def broadcast_presence_to_relevant_channels(status)
    begin
      last_seen = status == 'online' ? nil : Time.current.iso8601
      
      user_presence_data = {
        user_id: current_user.id,
        user_name: current_user.display_name || current_user.email || 'Unknown User',
        status: status,
        last_seen: last_seen,
        last_seen_at: last_seen,
        is_online: status == 'online',
        timestamp: Time.current.iso8601
      }
      
      business_ids = get_user_business_ids
      business_ids.each do |business_id|
        ActionCable.server.broadcast(
          "business_#{business_id}_updates",
          {
            type: 'member_presence_updated',
            **user_presence_data
          }
        )
      end
      
      if current_user.respond_to?(:conversations)
        active_conversation_ids = current_user.conversations
                                             .where("conversations.metadata->>'status' IN (?)", ['pending', 'in_progress'])
                                             .pluck(:id)
        
        active_conversation_ids.each do |conversation_id|
          ActionCable.server.broadcast(
            "conversation_#{conversation_id}",
            {
              type: 'user_presence_changed',
              conversation_id: conversation_id,
              **user_presence_data
            }
          )
        end
      end
      
    rescue => e
      Rails.logger.error "Failed to broadcast presence: #{e.message}"
    end
  end

  def send_initial_state
    begin
      notification_count = safe_count { current_user.notifications.unread.count }
      cart_count = calculate_cart_count
      unread_messages_count = calculate_unread_messages_count
      
      recent_conversations = get_recent_conversations
      business_info = get_user_businesses_info
      user_presence = get_user_presence_data(current_user.id)
      
      initial_state_data = {
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
          presence: user_presence
        },
        recent_conversations: recent_conversations,
        businesses: business_info,
        timestamp: Time.current.iso8601
      }
      
      if is_support_user?
        dashboard_stats = calculate_dashboard_stats
        agent_stats = calculate_agent_stats
        
        initial_state_data[:dashboard_stats] = dashboard_stats
        initial_state_data[:agent_stats] = agent_stats
      end
      
      transmit(initial_state_data)
      
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
      business_ids = []
      
      if current_user.respond_to?(:owned_businesses)
        business_ids += current_user.owned_businesses.pluck(:id)
      end
      
      if current_user.respond_to?(:user_businesses)
        business_ids += current_user.user_businesses.pluck(:business_id)
      end
      
      business_ids.uniq.each do |business_id|
        stream_from "business_#{business_id}_updates"
      end
      
      stream_from "user_businesses_#{current_user.id}"
      
    rescue => e
      Rails.logger.error "Failed to subscribe to business channels: #{e.message}"
    end
  end

  def subscribe_to_support_channels
    begin
      if is_support_user?
        stream_from "support_dashboard"
        stream_from "support_tickets"
      end
      
      if current_user.respond_to?(:conversations)
        active_conversation_ids = current_user.conversations
                                             .where("conversations.metadata->>'status' IN (?)", ['pending', 'in_progress'])
                                             .pluck(:id)
        
        active_conversation_ids.each do |conversation_id|
          stream_from "conversation_#{conversation_id}"
        end
      end
      
    rescue => e
      Rails.logger.error "Failed to subscribe to support channels: #{e.message}"
    end
  end

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
      
    rescue => e
      Rails.logger.error "Failed to broadcast notification counts: #{e.message}"
    end
  end

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
      
    rescue => e
      Rails.logger.error "Failed to broadcast message counts: #{e.message}"
    end
  end

  def calculate_cart_count
    return 0 unless current_user.respond_to?(:packages)
    safe_count { current_user.packages.where(state: 'pending_unpaid').count }
  rescue => e
    Rails.logger.error "Failed to calculate cart count: #{e.message}"
    0
  end

  def calculate_unread_messages_count
    return 0 unless current_user.respond_to?(:conversations)
    
    unread_count = 0
    current_user.conversations.includes(:messages, :conversation_participants).each do |conversation|
      begin
        last_read_at = conversation.last_read_at_for(current_user) if conversation.respond_to?(:last_read_at_for)
        
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

  def calculate_dashboard_stats
    return {} unless defined?(Conversation)
    
    begin
      total_tickets = Conversation.support_tickets.count
      pending_tickets = Conversation.support_tickets.where(status: 'pending').count
      in_progress_tickets = Conversation.support_tickets.where(status: 'in_progress').count
      
      resolved_today = Conversation.support_tickets
                                   .where(status: 'resolved')
                                   .where('updated_at >= ?', Time.current.beginning_of_day)
                                   .count
      
      {
        total_tickets: total_tickets,
        pending_tickets: pending_tickets,
        in_progress_tickets: in_progress_tickets,
        resolved_today: resolved_today,
        avg_response_time: '0m',
        satisfaction_score: 0,
        tickets_by_priority: {
          high: 0,
          normal: 0,
          low: 0
        }
      }
    rescue => e
      Rails.logger.error "Failed to calculate dashboard stats: #{e.message}"
      {}
    end
  end

  def calculate_agent_stats
    return {} unless defined?(Conversation)
    
    begin
      active_tickets = current_user.conversations
                                   .support_tickets
                                   .where(status: ['pending', 'in_progress', 'assigned'])
                                   .count
      
      tickets_resolved_today = current_user.conversations
                                           .support_tickets
                                           .where(status: 'resolved')
                                           .where('updated_at >= ?', Time.current.beginning_of_day)
                                           .count
      
      {
        tickets_resolved_today: tickets_resolved_today,
        avg_resolution_time: '0m',
        active_tickets: active_tickets,
        satisfaction_rating: 0
      }
    rescue => e
      Rails.logger.error "Failed to calculate agent stats: #{e.message}"
      {}
    end
  end

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
                    nil
                  end
                end.compact
  rescue => e
    Rails.logger.error "Failed to get recent conversations: #{e.message}"
    []
  end

  def get_user_businesses_info
    businesses = []
    
    begin
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
      Rails.logger.error "Failed to get user businesses: #{e.message}"
    end
    
    businesses
  end

  def get_user_business(business_id)
    if current_user.respond_to?(:owned_businesses)
      business = current_user.owned_businesses.find_by(id: business_id)
      return business if business
    end
    
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
    return true if current_user.respond_to?(:support_agent?) && current_user.support_agent?
    return true if current_user.respond_to?(:admin?) && current_user.admin?
    return true if current_user.email&.include?('@glt.co.ke')
    return true if current_user.email&.include?('support@')
    
    false
  rescue => e
    Rails.logger.error "Failed to check support user status: #{e.message}"
    false
  end

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