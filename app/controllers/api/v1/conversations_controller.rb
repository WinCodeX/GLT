# app/controllers/api/v1/conversations_controller.rb - Fixed with Push Notifications

class Api::V1::ConversationsController < ApplicationController
  include AvatarHelper
  
  before_action :authenticate_user!
  before_action :set_conversation, only: [:show, :close, :reopen, :accept_ticket, :send_message]

  # Configuration constants
  DEFAULT_MESSAGE_LIMIT = 20
  MAX_MESSAGE_LIMIT = 50
  PAGINATION_LIMIT = 15

  # GET /api/v1/conversations
  def index
    Rails.logger.info "Loading conversations for user #{current_user.id}"
    
    begin
      # Optimized query with minimal includes
      @conversations = current_user.conversations
                                  .includes(:conversation_participants, 
                                           last_message: :user,
                                           users: [])
                                  .recent

      if params[:type].present?
        case params[:type]
        when 'support'
          @conversations = @conversations.support_tickets
        when 'direct'
          @conversations = @conversations.direct_messages
        end
      end

      if params[:status].present? && params[:type] == 'support'
        @conversations = @conversations.where("metadata->>'status' = ?", params[:status])
      end

      page = [params[:page].to_i, 1].max
      @conversations = @conversations.limit(20).offset((page - 1) * 20)

      # Lightweight formatting for index
      conversation_data = @conversations.map do |conversation|
        efficiently_format_conversation_summary(conversation)
      end.compact

      render json: {
        success: true,
        conversations: conversation_data
      }
    rescue => e
      Rails.logger.error "Error in conversations#index: #{e.message}"
      render json: { success: false, message: 'Failed to load conversations' }, status: :internal_server_error
    end
  end

  # GET /api/v1/conversations/:id - OPTIMIZED for pagination
  def show
    Rails.logger.info "Loading conversation #{params[:id]} for user #{current_user.id}"
    
    begin
      unless @conversation
        Rails.logger.error "Conversation #{params[:id]} not found for user #{current_user.id}"
        return render json: { success: false, message: 'Conversation not found' }, status: :not_found
      end

      # Parse pagination parameters
      limit = parse_message_limit
      older_than = params[:older_than]

      Rails.logger.info "Loading messages with limit: #{limit}, older_than: #{older_than}"

      # OPTIMIZED: Load messages with proper pagination
      @messages = load_paginated_messages(@conversation, limit, older_than)
      
      # Determine if there are more messages
      has_more = check_has_more_messages(@conversation, @messages, older_than)

      # LIGHTWEIGHT: Only mark as read on initial load (not pagination)
      if older_than.blank?
        safely_mark_conversation_read(@conversation, current_user)
        safely_broadcast_conversation_read_status(@conversation, current_user)
      end

      # EFFICIENT: Format conversation and messages with minimal processing
      conversation_data = efficiently_format_conversation_detail(@conversation)
      messages_data = efficiently_format_messages(@messages)

      render json: {
        success: true,
        conversation: conversation_data,
        messages: messages_data,
        pagination: {
          has_more: has_more,
          limit: limit,
          count: @messages.size
        }
      }
    rescue => e
      Rails.logger.error "Error in conversations#show for conversation #{params[:id]}: #{e.message}"
      render json: { 
        success: false, 
        message: 'Failed to load conversation',
        error: Rails.env.development? ? e.message : 'Internal server error'
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/conversations/support_ticket
  def create_support_ticket
    Rails.logger.info "Creating support ticket with params: #{params.inspect}"
    
    begin
      package = safely_find_package_for_ticket
      existing_conversation = find_existing_active_ticket
      
      if existing_conversation
        Rails.logger.info "Found existing active ticket: #{existing_conversation.id}"
        return render json: {
          success: true,
          conversation: efficiently_format_conversation_detail(existing_conversation),
          conversation_id: existing_conversation.id,
          ticket_id: existing_conversation.ticket_id,
          message: 'Using existing support ticket'
        }
      end

      @conversation = Conversation.create_support_ticket(
        customer: current_user,
        category: params[:category] || 'general',
        package: package
      )

      if @conversation&.persisted?
        Rails.logger.info "Created support ticket: #{@conversation.id}"
        
        safely_broadcast_new_support_ticket(@conversation)
        
        render json: {
          success: true,
          conversation: efficiently_format_conversation_detail(@conversation),
          conversation_id: @conversation.id,
          ticket_id: @conversation.ticket_id,
          message: 'Support ticket created successfully'
        }, status: :created
      else
        error_messages = @conversation&.errors&.full_messages || ['Failed to create conversation']
        render json: { success: false, errors: error_messages }, status: :unprocessable_entity
      end
      
    rescue => e
      Rails.logger.error "Error creating support ticket: #{e.message}"
      render json: { 
        success: false, 
        message: 'Failed to create support ticket',
        error: Rails.env.development? ? e.message : 'Internal server error'
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/conversations/:id/send_message - FIXED with notifications
  def send_message
    Rails.logger.info "Sending message to conversation #{params[:id]}"
    
    begin
      unless @conversation
        return render json: { success: false, message: 'Conversation not found' }, status: :not_found
      end

      # Streamlined message creation
      @message = @conversation.messages.build(
        content: params[:content],
        message_type: params[:message_type] || 'text',
        user: current_user,
        metadata: parse_lightweight_metadata
      )

      if @message.save
        Rails.logger.info "Message saved successfully: #{@message.id}"
        
        # OPTIMIZED: Minimal updates
        @conversation.touch(:last_activity_at)
        update_support_ticket_status_if_needed
        
        # FIXED: Restore immediate notification sending for real-time experience
        if @conversation.support_ticket? && !@message.is_system?
          send_support_notifications_immediate(@message)
        end
        
        # ASYNC: Broadcast message updates (but not notifications, those are immediate)
        broadcast_message_updates_async(@conversation, @message)
        
        render json: {
          success: true,
          message: efficiently_format_message(@message),
          conversation: {
            id: @conversation.id,
            last_activity_at: @conversation.last_activity_at,
            status: @conversation.status
          }
        }
      else
        Rails.logger.error "Failed to save message: #{@message.errors.full_messages}"
        render json: { success: false, errors: @message.errors.full_messages }, status: :unprocessable_entity
      end
      
    rescue => e
      Rails.logger.error "Error sending message: #{e.message}"
      render json: { 
        success: false, 
        message: 'Failed to send message',
        error: Rails.env.development? ? e.message : 'Internal server error'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/conversations/active_support
  def active_support
    begin
      @conversation = current_user.conversations
                                 .support_tickets
                                 .where("metadata->>'status' IN (?)", ['pending', 'in_progress'])
                                 .order(:created_at)
                                 .last

      if @conversation
        render json: {
          success: true,
          conversation: efficiently_format_conversation_detail(@conversation),
          conversation_id: @conversation.id
        }
      else
        render json: { success: true, conversation: nil, conversation_id: nil }
      end
    rescue => e
      Rails.logger.error "Error getting active support: #{e.message}"
      render json: { success: false, message: 'Failed to get active support conversation' }, status: :internal_server_error
    end
  end

  # PATCH /api/v1/conversations/:id/accept_ticket
  def accept_ticket
    unless @conversation&.support_ticket?
      return render json: { success: false, message: 'Only support tickets can be accepted' }, status: :unprocessable_entity
    end

    unless current_user.support_agent? || current_user.admin?
      return render json: { success: false, message: 'Only support staff can accept tickets' }, status: :forbidden
    end

    begin
      @conversation.update_support_status('in_progress')
      
      unless @conversation.conversation_participants.exists?(user: current_user)
        @conversation.conversation_participants.create!(
          user: current_user,
          role: 'agent',
          joined_at: Time.current
        )
      end
      
      system_message = create_system_message(
        "Support ticket has been accepted by #{current_user.display_name}.",
        { type: 'ticket_accepted', agent_id: current_user.id, agent_name: current_user.display_name }
      )

      # Send notifications for ticket acceptance
      if system_message
        send_support_notifications_immediate(system_message)
      end

      safely_broadcast_ticket_status_change(@conversation, 'accepted', current_user, system_message)

      render json: { success: true, message: 'Support ticket accepted successfully' }
    rescue => e
      Rails.logger.error "Error accepting ticket: #{e.message}"
      render json: { success: false, message: 'Failed to accept ticket' }, status: :internal_server_error
    end
  end

  # PATCH /api/v1/conversations/:id/close
  def close
    unless @conversation&.support_ticket?
      return render json: { success: false, message: 'Only support tickets can be closed' }, status: :unprocessable_entity
    end

    begin
      @conversation.update_support_status('closed')
      
      system_message = create_system_message(
        'This support ticket has been closed.',
        { type: 'ticket_closed', closed_by: current_user.id }
      )

      # Send notifications for ticket closure
      if system_message
        send_support_notifications_immediate(system_message)
      end

      safely_broadcast_ticket_status_change(@conversation, 'closed', current_user, system_message)

      render json: { success: true, message: 'Support ticket closed successfully' }
    rescue => e
      Rails.logger.error "Error closing ticket: #{e.message}"
      render json: { success: false, message: 'Failed to close ticket' }, status: :internal_server_error
    end
  end

  # PATCH /api/v1/conversations/:id/reopen
  def reopen
    unless @conversation&.support_ticket?
      return render json: { success: false, message: 'Only support tickets can be reopened' }, status: :unprocessable_entity
    end

    begin
      @conversation.update_support_status('in_progress')
      
      system_message = create_system_message(
        'This support ticket has been reopened.',
        { type: 'ticket_reopened', reopened_by: current_user.id }
      )

      # Send notifications for ticket reopening
      if system_message
        send_support_notifications_immediate(system_message)
      end

      safely_broadcast_ticket_status_change(@conversation, 'reopened', current_user, system_message)

      render json: { success: true, message: 'Support ticket reopened successfully' }
    rescue => e
      Rails.logger.error "Error reopening ticket: #{e.message}"
      render json: { success: false, message: 'Failed to reopen ticket' }, status: :internal_server_error
    end
  end

  private

  def set_conversation
    @conversation = current_user.conversations.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error "Conversation #{params[:id]} not found for user #{current_user.id}"
    @conversation = nil
  rescue => e
    Rails.logger.error "Error finding conversation #{params[:id]}: #{e.message}"
    @conversation = nil
  end

  # OPTIMIZED: Parse message limit with bounds checking
  def parse_message_limit
    limit = params[:limit].to_i
    if limit <= 0
      DEFAULT_MESSAGE_LIMIT
    elsif limit > MAX_MESSAGE_LIMIT
      MAX_MESSAGE_LIMIT
    else
      limit
    end
  end

  # OPTIMIZED: Efficient message loading with cursor-based pagination
  def load_paginated_messages(conversation, limit, older_than)
    messages_query = conversation.messages
                                .includes(:user)
                                .order(created_at: :desc, id: :desc)

    if older_than.present?
      # Cursor-based pagination for older messages
      older_message = conversation.messages.find_by(id: older_than)
      if older_message
        messages_query = messages_query.where(
          '(created_at < ? OR (created_at = ? AND id < ?))',
          older_message.created_at,
          older_message.created_at,
          older_message.id
        )
      end
    end

    # Load one extra to check if there are more
    messages = messages_query.limit(limit + 1).to_a
    
    # Remove the extra message if we have more than requested
    if messages.size > limit
      messages.pop
    end

    # Reverse to get chronological order
    messages.reverse
  end

  # OPTIMIZED: Check if there are more messages efficiently
  def check_has_more_messages(conversation, loaded_messages, older_than)
    return false if loaded_messages.empty?
    
    oldest_loaded = loaded_messages.first
    
    if older_than.present?
      # For pagination, check if there are older messages than the oldest loaded
      conversation.messages
                 .where('created_at < ? OR (created_at = ? AND id < ?)',
                        oldest_loaded.created_at,
                        oldest_loaded.created_at,
                        oldest_loaded.id)
                 .exists?
    else
      # For initial load, check if there are older messages than the oldest loaded
      conversation.messages
                 .where('created_at < ? OR (created_at = ? AND id < ?)',
                        oldest_loaded.created_at,
                        oldest_loaded.created_at,
                        oldest_loaded.id)
                 .exists?
    end
  end

  # OPTIMIZED: Lightweight metadata parsing
  def parse_lightweight_metadata
    metadata = {}
    
    if params[:package_code].present?
      metadata[:package_code] = params[:package_code]
    end
    
    metadata
  rescue => e
    Rails.logger.error "Error parsing metadata: #{e.message}"
    {}
  end

  # OPTIMIZED: Minimal support ticket status update
  def update_support_ticket_status_if_needed
    return unless @conversation&.support_ticket? && @conversation.status == 'created'
    
    @conversation.update_support_status('pending')
    
    # Create system message asynchronously to avoid blocking
    Rails.logger.info "Support ticket status updated to pending"
  rescue => e
    Rails.logger.error "Error updating support ticket status: #{e.message}"
  end

  # FIXED: Immediate notification sending (restored from old controller)
  def send_support_notifications_immediate(message)
    Rails.logger.info "🔔 Creating immediate support notifications for message #{message.id}"
    
    # Get participants to notify (exclude message sender)
    participants_to_notify = @conversation.conversation_participants
                                        .includes(:user)
                                        .where.not(user: message.user)
    
    Rails.logger.info "👥 Found #{participants_to_notify.size} participants to notify"
    
    participants_to_notify.each do |participant|
      begin
        # Create notification immediately (not in background)
        create_notification_for_user_immediate(message, participant.user)
      rescue => e
        Rails.logger.error "❌ Failed to create immediate notification for user #{participant.user.id}: #{e.message}"
      end
    end
  end

  # FIXED: Create notification immediately (restored from old controller)
  def create_notification_for_user_immediate(message, recipient)
    Rails.logger.info "📝 Creating immediate notification for user #{recipient.id} (#{recipient.email})"
    
    # Determine if user is support based on email only (most reliable)
    is_support_user = recipient.email&.include?('@glt.co.ke') || recipient.email&.include?('support@')
    is_customer_sender = !message.from_support?
    
    # Determine notification content
    if is_customer_sender && is_support_user
      # Customer to Support Agent
      title = "New message from #{message.user.display_name}"
      notification_message = "Ticket ##{@conversation.ticket_id}: #{truncate_message(message.content)}"
      action_url = "/admin/support/conversations/#{@conversation.id}"
    else
      # Support Agent to Customer  
      title = "Customer Support replied"
      notification_message = truncate_message(message.content)
      action_url = "/support"
    end
    
    # Add package context if available
    package_code = @conversation.metadata&.dig('package_code')
    if package_code
      notification_message = "Package #{package_code}: #{notification_message}"
    end
    
    Rails.logger.info "📋 Notification details - Title: '#{title}', Message: '#{notification_message}'"
    
    # Create notification immediately
    notification = recipient.notifications.create!(
      title: title,
      message: notification_message,
      notification_type: 'support_message',
      channel: 'push',
      priority: 'normal',
      action_url: action_url,
      metadata: {
        conversation_id: @conversation.id,
        message_id: message.id,
        ticket_id: @conversation.ticket_id,
        package_code: package_code
      }.compact
    )
    
    Rails.logger.info "✅ Created notification #{notification.id}"
    
    # Send push notification immediately (critical for real-time experience)
    if recipient.push_tokens.active.any?
      Rails.logger.info "📱 Sending immediate push notification for notification #{notification.id}"
      
      begin
        # Send push notification immediately - this is what was missing!
        PushNotificationService.new.send_immediate(notification)
        Rails.logger.info "✅ Push notification sent successfully"
      rescue => e
        Rails.logger.error "❌ Push notification failed: #{e.message}"
      end
    else
      Rails.logger.warn "⚠️ No push tokens found for user #{recipient.id}"
    end
    
    notification
  end

  # ASYNC: Background job for heavy operations (but not notifications)
  def broadcast_message_updates_async(conversation, message)
    # Use background job for broadcasting only, notifications are immediate
    ConversationBroadcastJob.perform_later(conversation.id, message.id)
  rescue => e
    Rails.logger.error "Error queuing broadcast job: #{e.message}"
  end

  # OPTIMIZED: Efficient conversation summary formatting
  def efficiently_format_conversation_summary(conversation)
    return nil unless conversation
    
    last_message = conversation.last_message
    
    {
      id: conversation.id,
      conversation_type: conversation.conversation_type || 'unknown',
      title: conversation.title || 'Untitled Conversation',
      last_activity_at: conversation.last_activity_at,
      unread_count: 0, # Calculate separately if needed
      status_display: get_status_display(conversation.status),
      ticket_id: conversation.ticket_id,
      status: conversation.status,
      category: conversation.category,
      priority: conversation.priority,
      last_message: last_message ? {
        content: truncate_message(last_message.content),
        created_at: last_message.created_at,
        from_support: last_message.from_support? || false
      } : nil
    }
  rescue => e
    Rails.logger.error "Error formatting conversation summary: #{e.message}"
    { id: conversation.id, error: 'Failed to format conversation' }
  end

  # OPTIMIZED: Efficient conversation detail formatting
  def efficiently_format_conversation_detail(conversation)
    return nil unless conversation
    
    {
      id: conversation.id,
      conversation_type: conversation.conversation_type || 'unknown',
      title: conversation.title || 'Untitled Conversation',
      ticket_id: conversation.ticket_id,
      status: conversation.status,
      category: conversation.category,
      priority: conversation.priority,
      created_at: conversation.created_at,
      last_activity_at: conversation.last_activity_at,
      escalated: conversation.metadata&.dig('escalated') || false,
      customer: format_customer_data(conversation),
      assigned_agent: format_assigned_agent_data(conversation),
      metadata: conversation.metadata || {}
    }
  rescue => e
    Rails.logger.error "Error formatting conversation detail: #{e.message}"
    { id: conversation.id, error: 'Failed to format conversation' }
  end

  # OPTIMIZED: Batch format messages efficiently
  def efficiently_format_messages(messages)
    return [] unless messages.present?
    
    messages.map do |message|
      efficiently_format_message(message)
    end.compact
  rescue => e
    Rails.logger.error "Error batch formatting messages: #{e.message}"
    []
  end

  # OPTIMIZED: Lightweight message formatting
  def efficiently_format_message(message)
    return nil unless message
    
    {
      id: message.id,
      content: message.content || '',
      message_type: message.message_type || 'text',
      created_at: message.created_at,
      timestamp: format_timestamp(message.created_at),
      is_system: message.is_system? || false,
      from_support: message.from_support? || false,
      user: format_message_user(message.user),
      metadata: message.metadata || {}
    }
  rescue => e
    Rails.logger.error "Error formatting message #{message.id}: #{e.message}"
    { id: message.id, content: 'Error loading message', error: true }
  end

  # OPTIMIZED: Lightweight user formatting
  def format_message_user(user)
    return { id: nil, name: 'Unknown', role: 'unknown' } unless user
    
    {
      id: user.id,
      name: user.display_name || user.email || 'Unknown',
      role: determine_user_role(user),
      avatar_url: get_avatar_url_safely(user)
    }
  rescue => e
    Rails.logger.error "Error formatting user: #{e.message}"
    { id: user&.id, name: 'Unknown', role: 'unknown' }
  end

  # OPTIMIZED: Customer data formatting
  def format_customer_data(conversation)
    return nil unless conversation&.support_ticket?
    
    customer_participant = conversation.conversation_participants
                                     .includes(:user)
                                     .find_by(role: 'customer')
    
    return nil unless customer_participant&.user
    
    user = customer_participant.user
    {
      id: user.id,
      name: user.display_name || user.email || 'Unknown',
      email: user.email,
      avatar_url: get_avatar_url_safely(user)
    }
  rescue => e
    Rails.logger.error "Error formatting customer data: #{e.message}"
    nil
  end

  # OPTIMIZED: Agent data formatting
  def format_assigned_agent_data(conversation)
    return nil unless conversation&.support_ticket?
    
    agent_participant = conversation.conversation_participants
                                  .includes(:user)
                                  .find_by(role: 'agent')
    
    return nil unless agent_participant&.user
    
    user = agent_participant.user
    {
      id: user.id,
      name: user.display_name || user.email || 'Unknown',
      email: user.email,
      avatar_url: get_avatar_url_safely(user)
    }
  rescue => e
    Rails.logger.error "Error formatting agent data: #{e.message}"
    nil
  end

  # Helper methods
  def determine_user_role(user)
    return 'support' if user.respond_to?(:from_support?) && user.from_support?
    return 'support' if user.email&.include?('@glt.co.ke')
    'customer'
  rescue
    'unknown'
  end

  def get_avatar_url_safely(user)
    return nil unless user && respond_to?(:avatar_api_url)
    avatar_api_url(user)
  rescue
    nil
  end

  def format_timestamp(created_at)
    return '' unless created_at
    created_at.strftime('%H:%M')
  rescue
    ''
  end

  def get_status_display(status)
    case status
    when 'pending' then 'Ticket Pending'
    when 'in_progress' then 'Online'
    when 'closed' then 'Last seen recently'
    else 'Online'
    end
  end

  def create_system_message(content, metadata = {})
    @conversation.messages.create!(
      user: current_user,
      content: content,
      message_type: 'system',
      is_system: true,
      metadata: metadata
    )
  rescue => e
    Rails.logger.error "Error creating system message: #{e.message}"
    nil
  end

  def truncate_message(content)
    return '' unless content
    content.length > 100 ? "#{content[0..97]}..." : content
  end

  # Simplified safe methods (keeping only essential functionality)
  def safely_find_package_for_ticket
    return nil unless params[:package_code].present? || params[:package_id].present?
    
    if params[:package_code].present?
      current_user.packages.find_by(code: params[:package_code])
    elsif params[:package_id].present?
      current_user.packages.find_by(id: params[:package_id])
    end
  rescue => e
    Rails.logger.error "Error finding package: #{e.message}"
    nil
  end

  def find_existing_active_ticket
    Conversation.joins(:conversation_participants)
                .where(conversation_participants: { user_id: current_user.id })
                .support_tickets
                .where("metadata->>'status' IN (?)", ['pending', 'in_progress'])
                .where('conversations.created_at > ?', 24.hours.ago)
                .first
  rescue => e
    Rails.logger.error "Error finding existing ticket: #{e.message}"
    nil
  end

  def safely_mark_conversation_read(conversation, user)
    return unless conversation && user
    conversation.mark_read_by(user) if conversation.respond_to?(:mark_read_by)
  rescue => e
    Rails.logger.error "Error marking conversation as read: #{e.message}"
  end

  # Simplified broadcasting (keep only essential broadcasts)
  def safely_broadcast_new_support_ticket(conversation)
    ActionCable.server.broadcast(
      "support_tickets",
      {
        type: 'new_support_ticket',
        conversation_id: conversation.id,
        ticket_id: conversation.ticket_id,
        timestamp: Time.current.iso8601
      }
    )
  rescue => e
    Rails.logger.error "Error broadcasting new ticket: #{e.message}"
  end

  def safely_broadcast_conversation_read_status(conversation, reader)
    ActionCable.server.broadcast(
      "conversation_#{conversation.id}",
      {
        type: 'conversation_read',
        conversation_id: conversation.id,
        reader_id: reader.id,
        timestamp: Time.current.iso8601
      }
    )
  rescue => e
    Rails.logger.error "Error broadcasting read status: #{e.message}"
  end

  def safely_broadcast_ticket_status_change(conversation, action, actor, system_message)
    ActionCable.server.broadcast(
      "conversation_#{conversation.id}",
      {
        type: 'ticket_status_changed',
        conversation_id: conversation.id,
        action: action,
        new_status: conversation.status,
        system_message: system_message ? efficiently_format_message(system_message) : nil,
        timestamp: Time.current.iso8601
      }
    )
  rescue => e
    Rails.logger.error "Error broadcasting status change: #{e.message}"
  end
end