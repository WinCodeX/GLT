# app/controllers/api/v1/conversations_controller.rb
class Api::V1::ConversationsController < ApplicationController
  include AvatarHelper
  
  before_action :authenticate_user!
  before_action :set_conversation, only: [:show, :close, :reopen, :accept_ticket, :send_message]

  DEFAULT_MESSAGE_LIMIT = 20
  MAX_MESSAGE_LIMIT = 50

  # GET /api/v1/conversations
  def index
    Rails.logger.info "Loading conversations for user #{current_user.id}"
    
    begin
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

      # For support tickets, show all (don't filter by status)
      # Users can see their entire conversation history

      page = [params[:page].to_i, 1].max
      @conversations = @conversations.limit(20).offset((page - 1) * 20)

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

  # GET /api/v1/conversations/:id
  def show
    Rails.logger.info "Loading conversation #{params[:id]} for user #{current_user.id}"
    
    begin
      unless @conversation
        return render json: { success: false, message: 'Conversation not found' }, status: :not_found
      end

      limit = parse_message_limit
      older_than = params[:older_than]

      @messages = load_paginated_messages(@conversation, limit, older_than)
      has_more = check_has_more_messages(@conversation, @messages, older_than)

      if older_than.blank?
        safely_mark_conversation_read(@conversation, current_user)
        safely_broadcast_conversation_read_status(@conversation, current_user)
      end

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
      Rails.logger.error "Error in conversations#show: #{e.message}"
      render json: { 
        success: false, 
        message: 'Failed to load conversation',
        error: Rails.env.development? ? e.message : 'Internal server error'
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/conversations/support_ticket - FIXED
  def create_support_ticket
    Rails.logger.info "Creating support ticket for user #{current_user.id}"
    
    begin
      package = safely_find_package_for_ticket
      
      # Check if user already has a support conversation
      existing_conversation = Conversation.support_tickets.find_by(customer_id: current_user.id)
      
      if existing_conversation
        # Check if there's an active ticket
        if existing_conversation.current_ticket_id.present?
          Rails.logger.info "User has active ticket: #{existing_conversation.current_ticket_id}"
          return render json: {
            success: true,
            conversation: efficiently_format_conversation_detail(existing_conversation),
            conversation_id: existing_conversation.id,
            ticket_id: existing_conversation.current_ticket_id,
            message: 'You already have an active support ticket'
          }
        end
        
        # No active ticket, create new one in existing conversation
        Rails.logger.info "Creating new ticket in existing conversation #{existing_conversation.id}"
        existing_conversation.reopen_or_create_ticket(
          category: params[:category] || 'general',
          package: package
        )
        
        safely_broadcast_new_support_ticket(existing_conversation)
        
        return render json: {
          success: true,
          conversation: efficiently_format_conversation_detail(existing_conversation),
          conversation_id: existing_conversation.id,
          ticket_id: existing_conversation.current_ticket_id,
          message: 'New support ticket created'
        }, status: :created
      end

      # No existing conversation, create new one with first ticket
      @conversation = Conversation.create_support_ticket(
        customer: current_user,
        category: params[:category] || 'general',
        package: package
      )

      if @conversation&.persisted?
        Rails.logger.info "Created first support conversation: #{@conversation.id}"
        
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

  # POST /api/v1/conversations/:id/send_message
  def send_message
    Rails.logger.info "Sending message to conversation #{params[:id]}"
    
    begin
      unless @conversation
        return render json: { success: false, message: 'Conversation not found' }, status: :not_found
      end

      @message = @conversation.messages.build(
        content: params[:content],
        message_type: params[:message_type] || 'text',
        user: current_user,
        metadata: parse_lightweight_metadata
      )

      if @message.save
        Rails.logger.info "Message saved: #{@message.id}"
        
        @conversation.touch(:last_activity_at)
        update_support_ticket_status_if_needed
        
        if @conversation.support_ticket? && !@message.is_system?
          send_support_notifications_immediate(@message)
        end
        
        broadcast_message_updates_async(@conversation, @message)
        
        render json: {
          success: true,
          message: efficiently_format_message(@message),
          conversation: {
            id: @conversation.id,
            last_activity_at: @conversation.last_activity_at,
            status: @conversation.status,
            current_ticket_id: @conversation.current_ticket_id
          }
        }
      else
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

  # GET /api/v1/conversations/active_support - FIXED
  def active_support
    begin
      # Find user's support conversation (there should only be one)
      @conversation = current_user.conversations
                                 .support_tickets
                                 .find_by(customer_id: current_user.id)

      if @conversation
        render json: {
          success: true,
          conversation: efficiently_format_conversation_detail(@conversation),
          conversation_id: @conversation.id,
          has_active_ticket: @conversation.current_ticket_id.present?,
          current_ticket_id: @conversation.current_ticket_id
        }
      else
        render json: { 
          success: true, 
          conversation: nil, 
          conversation_id: nil,
          has_active_ticket: false
        }
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
        { type: 'ticket_accepted', agent_id: current_user.id, ticket_id: @conversation.current_ticket_id }
      )

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

  # PATCH /api/v1/conversations/:id/close - FIXED: Closes current ticket, not conversation
  def close
    unless @conversation&.support_ticket?
      return render json: { success: false, message: 'Only support tickets can be closed' }, status: :unprocessable_entity
    end

    begin
      old_ticket_id = @conversation.current_ticket_id
      
      # Close current ticket (not entire conversation)
      @conversation.close_current_ticket
      
      system_message = create_system_message(
        "Support ticket #{old_ticket_id} has been closed. You can create a new ticket anytime.",
        { type: 'ticket_closed', closed_by: current_user.id, ticket_id: old_ticket_id }
      )

      if system_message
        send_support_notifications_immediate(system_message)
      end

      safely_broadcast_ticket_status_change(@conversation, 'closed', current_user, system_message)

      render json: { 
        success: true, 
        message: 'Support ticket closed successfully',
        conversation_remains_open: true
      }
    rescue => e
      Rails.logger.error "Error closing ticket: #{e.message}"
      render json: { success: false, message: 'Failed to close ticket' }, status: :internal_server_error
    end
  end

  # PATCH /api/v1/conversations/:id/reopen - FIXED: Creates new ticket in same conversation
  def reopen
    unless @conversation&.support_ticket?
      return render json: { success: false, message: 'Only support tickets can be reopened' }, status: :unprocessable_entity
    end

    begin
      package = safely_find_package_for_ticket
      
      # Create new ticket in existing conversation
      @conversation.reopen_or_create_ticket(
        category: params[:category] || 'general',
        package: package
      )
      
      system_message = create_system_message(
        "New support ticket #{@conversation.current_ticket_id} created.",
        { type: 'ticket_reopened', reopened_by: current_user.id, ticket_id: @conversation.current_ticket_id }
      )

      if system_message
        send_support_notifications_immediate(system_message)
      end

      safely_broadcast_ticket_status_change(@conversation, 'reopened', current_user, system_message)

      render json: { 
        success: true, 
        message: 'New support ticket created successfully',
        ticket_id: @conversation.current_ticket_id
      }
    rescue => e
      Rails.logger.error "Error reopening ticket: #{e.message}"
      render json: { success: false, message: 'Failed to reopen ticket' }, status: :internal_server_error
    end
  end

  private

  def set_conversation
    @conversation = current_user.conversations.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    @conversation = nil
  end

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

  def load_paginated_messages(conversation, limit, older_than)
    messages_query = conversation.messages
                                .includes(:user)
                                .order(created_at: :desc, id: :desc)

    if older_than.present?
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

    messages = messages_query.limit(limit + 1).to_a
    messages.pop if messages.size > limit
    messages.reverse
  end

  def check_has_more_messages(conversation, loaded_messages, older_than)
    return false if loaded_messages.empty?
    
    oldest_loaded = loaded_messages.first
    
    conversation.messages
               .where('created_at < ? OR (created_at = ? AND id < ?)',
                      oldest_loaded.created_at,
                      oldest_loaded.created_at,
                      oldest_loaded.id)
               .exists?
  end

  def parse_lightweight_metadata
    metadata = {}
    metadata[:package_code] = params[:package_code] if params[:package_code].present?
    metadata[:ticket_id] = @conversation.current_ticket_id if @conversation&.current_ticket_id
    metadata
  rescue => e
    Rails.logger.error "Error parsing metadata: #{e.message}"
    {}
  end

  def update_support_ticket_status_if_needed
    return unless @conversation&.support_ticket? && @conversation.status == 'created'
    @conversation.update_support_status('pending')
  end

  def send_support_notifications_immediate(message)
    participants_to_notify = @conversation.conversation_participants
                                        .includes(:user)
                                        .where.not(user: message.user)
    
    participants_to_notify.each do |participant|
      begin
        create_notification_for_user_immediate(message, participant.user)
      rescue => e
        Rails.logger.error "Failed to create notification: #{e.message}"
      end
    end
  end

  def create_notification_for_user_immediate(message, recipient)
    is_support_user = recipient.email&.include?('@glt.co.ke') || recipient.email&.include?('support@')
    is_customer_sender = !message.from_support?
    
    if is_customer_sender && is_support_user
      title = "New message from #{message.user.display_name}"
      notification_message = "Ticket ##{@conversation.current_ticket_id || @conversation.ticket_id}: #{truncate_message(message.content)}"
      action_url = "/admin/support/conversations/#{@conversation.id}"
    else
      title = "Customer Support replied"
      notification_message = truncate_message(message.content)
      action_url = "/support"
    end
    
    package_code = @conversation.metadata&.dig('package_code')
    notification_message = "Package #{package_code}: #{notification_message}" if package_code
    
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
        ticket_id: @conversation.current_ticket_id || @conversation.ticket_id,
        package_code: package_code
      }.compact
    )
    
    if recipient.push_tokens.active.any?
      begin
        PushNotificationService.new.send_immediate(notification)
      rescue => e
        Rails.logger.error "Push notification failed: #{e.message}"
      end
    end
    
    notification
  end

  def broadcast_message_updates_async(conversation, message)
    ConversationBroadcastJob.perform_later(conversation.id, message.id)
  rescue => e
    Rails.logger.error "Error queuing broadcast: #{e.message}"
  end

  def efficiently_format_conversation_summary(conversation)
    return nil unless conversation
    
    last_message = conversation.last_message
    
    # Get ticket count and status
    all_tickets = conversation.all_tickets
    has_active_ticket = conversation.current_ticket_id.present?
    
    {
      id: conversation.id,
      conversation_type: conversation.conversation_type,
      title: conversation.title,
      last_activity_at: conversation.last_activity_at,
      unread_count: 0,
      status_display: get_status_display(conversation.status),
      ticket_id: conversation.current_ticket_id || conversation.ticket_id,
      status: conversation.status,
      category: conversation.category,
      priority: conversation.priority,
      total_tickets: all_tickets.size,
      has_active_ticket: has_active_ticket,
      last_message: last_message ? {
        content: truncate_message(last_message.content),
        created_at: last_message.created_at,
        from_support: last_message.from_support? || false
      } : nil
    }
  end

  def efficiently_format_conversation_detail(conversation)
    return nil unless conversation
    
    all_tickets = conversation.all_tickets
    
    {
      id: conversation.id,
      conversation_type: conversation.conversation_type,
      title: conversation.title,
      ticket_id: conversation.current_ticket_id || conversation.ticket_id,
      current_ticket_id: conversation.current_ticket_id,
      status: conversation.status,
      category: conversation.category,
      priority: conversation.priority,
      created_at: conversation.created_at,
      last_activity_at: conversation.last_activity_at,
      customer: format_customer_data(conversation),
      assigned_agent: format_assigned_agent_data(conversation),
      metadata: conversation.metadata || {},
      total_tickets: all_tickets.size,
      has_active_ticket: conversation.current_ticket_id.present?,
      all_tickets: all_tickets
    }
  end

  def efficiently_format_messages(messages)
    return [] unless messages.present?
    messages.map { |m| efficiently_format_message(m) }.compact
  end

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
  end

  def format_message_user(user)
    return { id: nil, name: 'Unknown', role: 'unknown' } unless user
    
    {
      id: user.id,
      name: user.display_name || user.email || 'Unknown',
      role: determine_user_role(user),
      avatar_url: get_avatar_url_safely(user)
    }
  end

  def format_customer_data(conversation)
    return nil unless conversation&.support_ticket?
    customer = conversation.customer
    return nil unless customer
    
    {
      id: customer.id,
      name: customer.display_name || customer.email,
      email: customer.email,
      avatar_url: get_avatar_url_safely(customer)
    }
  end

  def format_assigned_agent_data(conversation)
    return nil unless conversation&.support_ticket?
    agent = conversation.assigned_agent
    return nil unless agent
    
    {
      id: agent.id,
      name: agent.display_name || agent.email,
      email: agent.email,
      avatar_url: get_avatar_url_safely(agent)
    }
  end

  def determine_user_role(user)
    return 'support' if user.email&.include?('@glt.co.ke')
    'customer'
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

  def safely_find_package_for_ticket
    return nil unless params[:package_code].present? || params[:package_id].present?
    
    if params[:package_code].present?
      current_user.packages.find_by(code: params[:package_code])
    elsif params[:package_id].present?
      current_user.packages.find_by(id: params[:package_id])
    end
  rescue
    nil
  end

  def safely_mark_conversation_read(conversation, user)
    return unless conversation && user
    conversation.mark_read_by(user) if conversation.respond_to?(:mark_read_by)
  rescue => e
    Rails.logger.error "Error marking as read: #{e.message}"
  end

  def safely_broadcast_new_support_ticket(conversation)
    ActionCable.server.broadcast("support_tickets", {
      type: 'new_support_ticket',
      conversation_id: conversation.id,
      ticket_id: conversation.current_ticket_id,
      timestamp: Time.current.iso8601
    })
  rescue => e
    Rails.logger.error "Error broadcasting: #{e.message}"
  end

  def safely_broadcast_conversation_read_status(conversation, reader)
    ActionCable.server.broadcast("conversation_#{conversation.id}", {
      type: 'conversation_read',
      conversation_id: conversation.id,
      reader_id: reader.id,
      timestamp: Time.current.iso8601
    })
  rescue => e
    Rails.logger.error "Error broadcasting: #{e.message}"
  end

  def safely_broadcast_ticket_status_change(conversation, action, actor, system_message)
    ActionCable.server.broadcast("conversation_#{conversation.id}", {
      type: 'ticket_status_changed',
      conversation_id: conversation.id,
      action: action,
      new_status: conversation.status,
      current_ticket_id: conversation.current_ticket_id,
      system_message: system_message ? efficiently_format_message(system_message) : nil,
      timestamp: Time.current.iso8601
    })
  rescue => e
    Rails.logger.error "Error broadcasting: #{e.message}"
  end
end