# app/controllers/api/v1/conversations_controller.rb - Performance optimized with ActionCable
class Api::V1::ConversationsController < ApplicationController
  include AvatarHelper
  
  before_action :authenticate_user!
  before_action :set_conversation, only: [:show, :close, :reopen, :accept_ticket, :send_message]

  # GET /api/v1/conversations
  def index
    @conversations = current_user.conversations
                                .includes(:conversation_participants, :users, :messages)
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

    render json: {
      success: true,
      conversations: @conversations.map { |conversation| format_conversation_summary(conversation) }
    }
  rescue => e
    Rails.logger.error "Error in conversations#index: #{e.message}"
    render json: { success: false, message: 'Failed to load conversations' }, status: :internal_server_error
  end

  # GET /api/v1/conversations/:id
  def show
    begin
      @conversation.mark_read_by(current_user) if @conversation.respond_to?(:mark_read_by)
      
      # ENHANCED: Support pagination for lazy loading
      page = [params[:page].to_i, 1].max
      limit = [params[:limit].to_i, 50].min
      limit = 50 if limit <= 0
      
      @messages = @conversation.messages
                              .includes(:user)
                              .order(created_at: :desc)
                              .limit(limit)
                              .offset((page - 1) * limit)
                              .reverse

      # Broadcast read status via ActionCable
      broadcast_conversation_read(@conversation, current_user)

      render json: {
        success: true,
        conversation: format_conversation_detail(@conversation),
        messages: @messages.map { |message| format_message(message) },
        pagination: {
          page: page,
          limit: limit,
          has_more: @conversation.messages.count > (page * limit)
        }
      }
    rescue => e
      Rails.logger.error "Error in conversations#show: #{e.message}"
      render json: { success: false, message: 'Failed to load conversation' }, status: :internal_server_error
    end
  end

  # POST /api/v1/conversations/support_ticket
  def create_support_ticket
    Rails.logger.info "Creating support ticket with params: #{params.inspect}"
    
    begin
      package = find_package_for_ticket
      existing_conversation = find_existing_active_ticket
      
      if existing_conversation
        Rails.logger.info "Found existing active ticket: #{existing_conversation.id}"
        return render json: {
          success: true,
          conversation: format_conversation_detail(existing_conversation),
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

      if @conversation.persisted?
        Rails.logger.info "Created support ticket: #{@conversation.id}"
        
        # Broadcast new ticket via ActionCable
        broadcast_new_support_ticket(@conversation)
        
        render json: {
          success: true,
          conversation: format_conversation_detail(@conversation),
          conversation_id: @conversation.id,
          ticket_id: @conversation.ticket_id,
          message: 'Support ticket created successfully'
        }, status: :created
      else
        render json: { success: false, errors: @conversation.errors.full_messages }, status: :unprocessable_entity
      end
      
    rescue => e
      Rails.logger.error "Error creating support ticket: #{e.message}"
      render json: { success: false, message: 'Failed to create support ticket', error: e.message }, status: :internal_server_error
    end
  end

  # POST /api/v1/conversations/:id/send_message
  def send_message
    Rails.logger.info "Sending message to conversation #{params[:id]}"
    
    begin
      message_metadata = parse_message_metadata(@conversation)
      
      message_params = {
        content: params[:content],
        message_type: params[:message_type] || 'text',
        metadata: message_metadata
      }

      @message = @conversation.messages.build(message_params)
      @message.user = current_user

      if @message.save
        @conversation.touch(:last_activity_at)
        update_support_ticket_status if @conversation.support_ticket?

        # Broadcast new message via ActionCable
        broadcast_new_message(@conversation, @message)

        # Send notifications for support tickets
        if @conversation.support_ticket? && !@message.is_system?
          send_support_notifications(@message)
        end

        Rails.logger.info "Message saved successfully: #{@message.id}"
        
        render json: {
          success: true,
          message: format_message(@message),
          conversation: format_conversation_detail(@conversation)
        }
      else
        render json: { success: false, errors: @message.errors.full_messages }, status: :unprocessable_entity
      end
      
    rescue => e
      Rails.logger.error "Error sending message: #{e.message}"
      render json: { success: false, message: 'Failed to send message', error: e.message }, status: :internal_server_error
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
          conversation: format_conversation_detail(@conversation),
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
    unless @conversation.support_ticket?
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
      
      system_message = @conversation.messages.create!(
        user: current_user,
        content: "Support ticket has been accepted by #{current_user.display_name}.",
        message_type: 'system',
        is_system: true,
        metadata: { 
          type: 'ticket_accepted',
          agent_id: current_user.id,
          agent_name: current_user.display_name
        }
      )

      # Broadcast ticket acceptance
      broadcast_ticket_status_change(@conversation, 'accepted', current_user, system_message)

      render json: { success: true, message: 'Support ticket accepted successfully' }
    rescue => e
      Rails.logger.error "Error accepting ticket: #{e.message}"
      render json: { success: false, message: 'Failed to accept ticket' }, status: :internal_server_error
    end
  end

  # PATCH /api/v1/conversations/:id/close
  def close
    unless @conversation.support_ticket?
      return render json: { success: false, message: 'Only support tickets can be closed' }, status: :unprocessable_entity
    end

    begin
      @conversation.update_support_status('closed')
      
      system_message = @conversation.messages.create!(
        user: current_user,
        content: 'This support ticket has been closed.',
        message_type: 'system',
        is_system: true,
        metadata: { type: 'ticket_closed', closed_by: current_user.id }
      )

      # Broadcast ticket closure
      broadcast_ticket_status_change(@conversation, 'closed', current_user, system_message)

      render json: { success: true, message: 'Support ticket closed successfully' }
    rescue => e
      Rails.logger.error "Error closing ticket: #{e.message}"
      render json: { success: false, message: 'Failed to close ticket' }, status: :internal_server_error
    end
  end

  # PATCH /api/v1/conversations/:id/reopen
  def reopen
    unless @conversation.support_ticket?
      return render json: { success: false, message: 'Only support tickets can be reopened' }, status: :unprocessable_entity
    end

    begin
      @conversation.update_support_status('in_progress')
      
      system_message = @conversation.messages.create!(
        user: current_user,
        content: 'This support ticket has been reopened.',
        message_type: 'system',
        is_system: true,
        metadata: { type: 'ticket_reopened', reopened_by: current_user.id }
      )

      # Broadcast ticket reopening
      broadcast_ticket_status_change(@conversation, 'reopened', current_user, system_message)

      render json: { success: true, message: 'Support ticket reopened successfully' }
    rescue => e
      Rails.logger.error "Error reopening ticket: #{e.message}"
      render json: { success: false, message: 'Failed to reopen ticket' }, status: :internal_server_error
    end
  end

  private

  # ENHANCED: ActionCable broadcasting methods
  def broadcast_new_support_ticket(conversation)
    begin
      customer = get_customer_from_conversation(conversation)
      package = find_package_for_conversation(conversation)
      
      ActionCable.server.broadcast(
        "support_tickets",
        {
          type: 'new_support_ticket',
          conversation: {
            id: conversation.id,
            ticket_id: conversation.ticket_id,
            category: conversation.category,
            priority: conversation.priority,
            status: conversation.status,
            created_at: conversation.created_at.iso8601
          },
          customer: format_customer_data(customer),
          package: package ? { id: package.id, code: package.code, state: package.state } : nil,
          timestamp: Time.current.iso8601
        }
      )
      
      if customer
        ActionCable.server.broadcast(
          "user_messages_#{customer.id}",
          {
            type: 'support_ticket_created',
            conversation_id: conversation.id,
            ticket_id: conversation.ticket_id,
            timestamp: Time.current.iso8601
          }
        )
      end
      
      Rails.logger.info "📡 New support ticket broadcast sent"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast new support ticket: #{e.message}"
    end
  end

  def broadcast_new_message(conversation, message)
    begin
      # Broadcast to conversation channel
      ActionCable.server.broadcast(
        "conversation_#{conversation.id}",
        {
          type: 'new_message',
          conversation_id: conversation.id,
          message: format_message(message),
          timestamp: Time.current.iso8601
        }
      )
      
      # Broadcast to participant channels
      conversation.conversation_participants.includes(:user).each do |participant|
        next if participant.user == message.user # Don't notify sender
        
        ActionCable.server.broadcast(
          "user_messages_#{participant.user.id}",
          {
            type: 'conversation_activity',
            conversation_id: conversation.id,
            unread_count: conversation.unread_count_for(participant.user),
            last_message: {
              content: truncate_message(message.content),
              from_support: message.from_support?,
              created_at: message.created_at.iso8601
            },
            timestamp: Time.current.iso8601
          }
        )
      end
      
      Rails.logger.info "📡 New message broadcast sent"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast new message: #{e.message}"
    end
  end

  def broadcast_conversation_read(conversation, reader)
    begin
      ActionCable.server.broadcast(
        "conversation_#{conversation.id}",
        {
          type: 'conversation_read',
          conversation_id: conversation.id,
          reader_id: reader.id,
          reader_name: reader.display_name,
          timestamp: Time.current.iso8601
        }
      )
      
      ActionCable.server.broadcast(
        "user_messages_#{reader.id}",
        {
          type: 'conversation_read_update',
          conversation_id: conversation.id,
          unread_count: 0,
          timestamp: Time.current.iso8601
        }
      )
      
      Rails.logger.info "📡 Conversation read broadcast sent"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast read status: #{e.message}"
    end
  end

  def broadcast_ticket_status_change(conversation, action, actor, system_message)
    begin
      customer = get_customer_from_conversation(conversation)
      assigned_agent = get_assigned_agent_from_conversation(conversation)
      
      # Broadcast to conversation channel
      ActionCable.server.broadcast(
        "conversation_#{conversation.id}",
        {
          type: 'ticket_status_changed',
          conversation_id: conversation.id,
          ticket_id: conversation.ticket_id,
          action: action,
          new_status: conversation.status,
          actor: {
            id: actor.id,
            name: actor.display_name,
            role: actor.from_support? ? 'support' : 'customer'
          },
          system_message: format_message(system_message),
          timestamp: Time.current.iso8601
        }
      )
      
      # Broadcast to support agents
      ActionCable.server.broadcast(
        "support_tickets",
        {
          type: 'ticket_status_updated',
          conversation_id: conversation.id,
          ticket_id: conversation.ticket_id,
          status: conversation.status,
          action: action,
          customer: format_customer_data(customer),
          assigned_agent: format_agent_data(assigned_agent),
          timestamp: Time.current.iso8601
        }
      )
      
      # Broadcast to customer
      if customer
        ActionCable.server.broadcast(
          "user_messages_#{customer.id}",
          {
            type: 'support_ticket_status_changed',
            conversation_id: conversation.id,
            ticket_id: conversation.ticket_id,
            status: conversation.status,
            action: action,
            timestamp: Time.current.iso8601
          }
        )
      end
      
      Rails.logger.info "📡 Ticket status change broadcast sent"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast ticket status change: #{e.message}"
    end
  end

  def set_conversation
    @conversation = current_user.conversations.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, message: 'Conversation not found' }, status: :not_found
  end

  def find_package_for_ticket
    package = nil
    
    if params[:package_code].present?
      package = current_user.packages.find_by(code: params[:package_code])
      unless package
        Rails.logger.warn "Package not found with code: #{params[:package_code]}"
        raise ActiveRecord::RecordNotFound, 'Package not found'
      end
    elsif params[:package_id].present?
      package = current_user.packages.find_by(id: params[:package_id])
      unless package
        Rails.logger.warn "Package not found with id: #{params[:package_id]}"
        raise ActiveRecord::RecordNotFound, 'Package not found'
      end
    end
    
    package
  end

  def find_existing_active_ticket
    Conversation.joins(:conversation_participants)
                .where(conversation_participants: { user_id: current_user.id })
                .support_tickets
                .where("metadata->>'status' IN (?)", ['pending', 'in_progress'])
                .where('conversations.created_at > ?', 24.hours.ago)
                .first
  end

  def parse_message_metadata(conversation)
    metadata = params[:metadata] || {}
    metadata = {} unless metadata.is_a?(Hash)
    
    if params[:package_code].present?
      metadata[:package_code] = params[:package_code]
      
      if conversation.support_ticket? && conversation.category == 'basic_inquiry'
        begin
          package = Package.find_by(code: params[:package_code])
          if package && package.user == current_user
            conversation.metadata ||= {}
            conversation.metadata['package_id'] = package.id
            conversation.metadata['package_code'] = package.code
            conversation.metadata['category'] = 'package_inquiry'
            conversation.save!
            Rails.logger.info "Upgraded basic inquiry to package inquiry for package: #{package.code}"
          end
        rescue => e
          Rails.logger.warn "Failed to upgrade conversation to package inquiry: #{e.message}"
        end
      end
    end
    
    if metadata[:package_code].blank?
      package = find_package_for_conversation(conversation)
      if package
        metadata[:package_code] = package.code
        Rails.logger.info "Inherited package code from conversation context: #{package.code}"
      end
    end
    
    metadata
  end

  def update_support_ticket_status
    if @conversation.status == 'created'
      @conversation.update_support_status('pending')
      
      @conversation.messages.create!(
        user: current_user,
        content: "Support ticket ##{@conversation.ticket_id} has been created and is pending review.",
        message_type: 'system',
        is_system: true,
        metadata: { type: 'ticket_created' }
      )
    end
  end

  def send_support_notifications(message)
    Rails.logger.info "🔔 Creating support notifications for message #{message.id}"
    
    participants_to_notify = @conversation.conversation_participants
                                        .includes(:user)
                                        .where.not(user: message.user)
    
    participants_to_notify.each do |participant|
      begin
        create_notification_for_user(message, participant.user)
      rescue => e
        Rails.logger.error "❌ Failed to create notification for user #{participant.user.id}: #{e.message}"
      end
    end
  end

  def create_notification_for_user(message, recipient)
    Rails.logger.info "📝 Creating notification for user #{recipient.id}"
    
    is_support_user = recipient.email&.include?('@glt.co.ke') || recipient.email&.include?('support@')
    is_customer_sender = !message.from_support?
    
    if is_customer_sender && is_support_user
      title = "New message from #{message.user.display_name}"
      notification_message = "Ticket ##{@conversation.ticket_id}: #{truncate_message(message.content)}"
      action_url = "/admin/support/conversations/#{@conversation.id}"
    else
      title = "Customer Support replied"
      notification_message = truncate_message(message.content)
      action_url = "/support"
    end
    
    package_code = @conversation.metadata&.dig('package_code')
    if package_code
      notification_message = "Package #{package_code}: #{notification_message}"
    end
    
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
    
    if recipient.push_tokens.active.any?
      begin
        PushNotificationService.new.send_immediate(notification)
      rescue => e
        Rails.logger.error "❌ Push notification failed: #{e.message}"
      end
    end
    
    notification
  end

  def get_customer_from_conversation(conversation)
    if conversation.support_ticket?
      customer_participant = conversation.conversation_participants
                                       .includes(:user)
                                       .find_by(role: 'customer')
      return customer_participant&.user
    end
    
    if conversation.direct_message?
      return conversation.other_participant(current_user)
    end
    
    nil
  end

  def get_assigned_agent_from_conversation(conversation)
    return nil unless conversation.support_ticket?
    
    agent_participant = conversation.conversation_participants
                                  .includes(:user)
                                  .find_by(role: 'agent')
    agent_participant&.user
  end

  def format_customer_data(customer)
    return nil unless customer
    
    {
      id: customer.id,
      name: customer.display_name,
      email: customer.email,
      avatar_url: avatar_api_url(customer)
    }
  end

  def format_agent_data(agent)
    return nil unless agent
    
    {
      id: agent.id,
      name: agent.display_name,
      email: agent.email,
      avatar_url: avatar_api_url(agent)
    }
  end

  def format_conversation_summary(conversation)
    last_message = conversation.last_message
    customer = get_customer_from_conversation(conversation)
    assigned_agent = get_assigned_agent_from_conversation(conversation)
    other_participant = conversation.other_participant(current_user) if conversation.direct_message?

    status_display = case conversation.status
    when 'pending'
      'Ticket Pending'
    when 'in_progress'
      'Online'
    when 'closed'
      'Last seen recently'
    else
      'Online'
    end

    {
      id: conversation.id,
      conversation_type: conversation.conversation_type,
      title: conversation.title,
      last_activity_at: conversation.last_activity_at,
      unread_count: conversation.unread_count_for(current_user),
      status_display: status_display,
      ticket_id: conversation.ticket_id,
      status: conversation.status,
      category: conversation.category,
      priority: conversation.priority,
      customer: format_customer_data(customer),
      assigned_agent: format_agent_data(assigned_agent),
      other_participant: other_participant ? format_customer_data(other_participant) : nil,
      last_message: last_message ? {
        content: truncate_message(last_message.content),
        created_at: last_message.created_at,
        from_support: last_message.from_support?
      } : nil,
      participants: conversation.conversation_participants.includes(:user).map do |participant|
        {
          user_id: participant.user.id,
          name: participant.user.display_name,
          role: participant.role,
          joined_at: participant.joined_at,
          avatar_url: avatar_api_url(participant.user)
        }
      end
    }
  rescue => e
    Rails.logger.error "Error formatting conversation summary: #{e.message}"
    {
      id: conversation.id,
      conversation_type: conversation.conversation_type,
      title: conversation.title || 'Untitled Conversation',
      error: 'Failed to load conversation details'
    }
  end

  def format_conversation_detail(conversation)
    base_summary = format_conversation_summary(conversation)
    customer = get_customer_from_conversation(conversation)
    assigned_agent = get_assigned_agent_from_conversation(conversation)
    
    additional_details = {
      metadata: conversation.metadata || {},
      created_at: conversation.created_at,
      updated_at: conversation.updated_at,
      escalated: conversation.metadata&.dig('escalated') || false,
      message_count: conversation.messages.count,
      customer: format_customer_data(customer),
      assigned_agent: format_agent_data(assigned_agent),
      package: nil
    }

    package = find_package_for_conversation(conversation)
    
    if package
      additional_details[:package] = {
        id: package.id,
        code: package.code,
        state: package.state,
        state_display: package.state_display,
        receiver_name: package.receiver_name,
        route_description: package.route_description,
        cost: package.cost,
        delivery_type: package.delivery_type,
        created_at: package.created_at
      }
    end

    base_summary.merge(additional_details)
  rescue => e
    Rails.logger.error "Error formatting conversation detail: #{e.message}"
    format_conversation_summary(conversation)
  end

  def format_message(message)
    {
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      metadata: message.metadata || {},
      created_at: message.created_at,
      timestamp: message.formatted_timestamp,
      is_system: message.is_system?,
      from_support: message.from_support?,
      user: {
        id: message.user.id,
        name: message.user.display_name,
        role: message.from_support? ? 'support' : 'customer',
        avatar_url: avatar_api_url(message.user)
      }
    }
  rescue => e
    Rails.logger.error "Error formatting message: #{e.message}"
    {
      id: message.id,
      content: message.content || 'Error loading message',
      metadata: {},
      error: 'Failed to format message'
    }
  end

  def find_package_for_conversation(conversation)
    package = nil
    
    if conversation.metadata&.dig('package_id')
      begin
        package = Package.find(conversation.metadata['package_id'])
        return package
      rescue ActiveRecord::RecordNotFound
        Rails.logger.warn "Package not found for conversation metadata package_id: #{conversation.metadata['package_id']}"
      end
    end
    
    if conversation.metadata&.dig('package_code')
      begin
        package = Package.find_by(code: conversation.metadata['package_code'])
        return package if package
      rescue => e
        Rails.logger.warn "Error finding package by conversation metadata: #{e.message}"
      end
    end
    
    begin
      message_with_package = conversation.messages
                                       .where("metadata->>'package_code' IS NOT NULL")
                                       .first
      if message_with_package&.metadata&.dig('package_code')
        package = Package.find_by(code: message_with_package.metadata['package_code'])
        return package if package
      end
    rescue => e
      Rails.logger.warn "Error finding package from message metadata: #{e.message}"
    end
    
    nil
  end

  def truncate_message(content)
    return '' unless content
    content.length > 100 ? "#{content[0..97]}..." : content
  end
end