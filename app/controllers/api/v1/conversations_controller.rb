# app/controllers/api/v1/conversations_controller.rb - Enhanced with robust error handling and ActionCable broadcasting

class Api::V1::ConversationsController < ApplicationController
  include AvatarHelper
  
  before_action :authenticate_user!
  before_action :set_conversation, only: [:show, :close, :reopen, :accept_ticket, :send_message]

  # GET /api/v1/conversations
  def index
    Rails.logger.info "Loading conversations for user #{current_user.id}"
    
    begin
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

      conversation_data = @conversations.map do |conversation|
        safely_format_conversation_summary(conversation)
      end.compact

      render json: {
        success: true,
        conversations: conversation_data
      }
    rescue => e
      Rails.logger.error "Error in conversations#index: #{e.message}\n#{e.backtrace.join("\n")}"
      render json: { success: false, message: 'Failed to load conversations' }, status: :internal_server_error
    end
  end

  # GET /api/v1/conversations/:id
  def show
    Rails.logger.info "Loading conversation #{params[:id]} for user #{current_user.id}"
    
    begin
      # CRITICAL FIX: Add safety checks and better error handling
      unless @conversation
        Rails.logger.error "Conversation #{params[:id]} not found for user #{current_user.id}"
        return render json: { success: false, message: 'Conversation not found' }, status: :not_found
      end

      # ENHANCED: Safely mark as read with error handling
      begin
        safely_mark_conversation_read(@conversation, current_user)
      rescue => e
        Rails.logger.warn "Failed to mark conversation as read: #{e.message}"
        # Don't fail the whole request if marking read fails
      end

      # ENHANCED: Safely load messages with error handling
      @messages = safely_load_conversation_messages(@conversation)

      # ENHANCED: Safely broadcast read status
      begin
        broadcast_conversation_read_status(@conversation, current_user)
      rescue => e
        Rails.logger.warn "Failed to broadcast read status: #{e.message}"
        # Don't fail the whole request if broadcast fails
      end

      # ENHANCED: Safely format conversation and messages
      conversation_data = safely_format_conversation_detail(@conversation)
      messages_data = @messages.map { |message| safely_format_message(message) }.compact

      render json: {
        success: true,
        conversation: conversation_data,
        messages: messages_data
      }
    rescue => e
      Rails.logger.error "Error in conversations#show for conversation #{params[:id]}: #{e.message}\n#{e.backtrace.join("\n")}"
      render json: { success: false, message: 'Failed to load conversation', error: e.message }, status: :internal_server_error
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
          conversation: safely_format_conversation_detail(existing_conversation),
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
        
        # ENHANCED: Safely broadcast new support ticket
        safely_broadcast_new_support_ticket(@conversation)
        
        render json: {
          success: true,
          conversation: safely_format_conversation_detail(@conversation),
          conversation_id: @conversation.id,
          ticket_id: @conversation.ticket_id,
          message: 'Support ticket created successfully'
        }, status: :created
      else
        error_messages = @conversation&.errors&.full_messages || ['Failed to create conversation']
        render json: { success: false, errors: error_messages }, status: :unprocessable_entity
      end
      
    rescue => e
      Rails.logger.error "Error creating support ticket: #{e.message}\n#{e.backtrace.join("\n")}"
      render json: { success: false, message: 'Failed to create support ticket', error: e.message }, status: :internal_server_error
    end
  end

  # POST /api/v1/conversations/:id/send_message
  def send_message
    Rails.logger.info "Sending message to conversation #{params[:id]} with content: #{params[:content]&.truncate(50)}"
    
    begin
      unless @conversation
        return render json: { success: false, message: 'Conversation not found' }, status: :not_found
      end

      message_metadata = safely_parse_message_metadata(@conversation)
      
      message_params = {
        content: params[:content],
        message_type: params[:message_type] || 'text',
        metadata: message_metadata
      }

      @message = @conversation.messages.build(message_params)
      @message.user = current_user

      if @message.save
        Rails.logger.info "Message saved successfully: #{@message.id}"
        
        # ENHANCED: Safely update conversation
        safely_update_conversation_after_message(@conversation)
        
        # ENHANCED: Safely update support ticket status
        safely_update_support_ticket_status if @conversation.support_ticket?

        # ENHANCED: Safely broadcast updates
        safely_broadcast_conversation_update(@conversation, @message)
        
        # ENHANCED: Safely send notifications
        safely_send_support_notifications(@message) if @conversation.support_ticket? && !@message.is_system?

        render json: {
          success: true,
          message: safely_format_message(@message),
          conversation: safely_format_conversation_detail(@conversation)
        }
      else
        Rails.logger.error "Failed to save message: #{@message.errors.full_messages}"
        render json: { success: false, errors: @message.errors.full_messages }, status: :unprocessable_entity
      end
      
    rescue => e
      Rails.logger.error "Error sending message: #{e.message}\n#{e.backtrace.join("\n")}"
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
          conversation: safely_format_conversation_detail(@conversation),
          conversation_id: @conversation.id
        }
      else
        render json: { success: true, conversation: nil, conversation_id: nil }
      end
    rescue => e
      Rails.logger.error "Error getting active support: #{e.message}\n#{e.backtrace.join("\n")}"
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

      # ENHANCED: Safely broadcast ticket acceptance
      safely_broadcast_ticket_status_change(@conversation, 'accepted', current_user, system_message)

      render json: { success: true, message: 'Support ticket accepted successfully' }
    rescue => e
      Rails.logger.error "Error accepting ticket: #{e.message}\n#{e.backtrace.join("\n")}"
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
      
      system_message = @conversation.messages.create!(
        user: current_user,
        content: 'This support ticket has been closed.',
        message_type: 'system',
        is_system: true,
        metadata: { type: 'ticket_closed', closed_by: current_user.id }
      )

      # ENHANCED: Safely broadcast ticket closure
      safely_broadcast_ticket_status_change(@conversation, 'closed', current_user, system_message)

      render json: { success: true, message: 'Support ticket closed successfully' }
    rescue => e
      Rails.logger.error "Error closing ticket: #{e.message}\n#{e.backtrace.join("\n")}"
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
      
      system_message = @conversation.messages.create!(
        user: current_user,
        content: 'This support ticket has been reopened.',
        message_type: 'system',
        is_system: true,
        metadata: { type: 'ticket_reopened', reopened_by: current_user.id }
      )

      # ENHANCED: Safely broadcast ticket reopening
      safely_broadcast_ticket_status_change(@conversation, 'reopened', current_user, system_message)

      render json: { success: true, message: 'Support ticket reopened successfully' }
    rescue => e
      Rails.logger.error "Error reopening ticket: #{e.message}\n#{e.backtrace.join("\n")}"
      render json: { success: false, message: 'Failed to reopen ticket' }, status: :internal_server_error
    end
  end

  private

  # ENHANCED: Safe conversation read marking
  def safely_mark_conversation_read(conversation, user)
    return unless conversation && user
    
    if conversation.respond_to?(:mark_read_by)
      conversation.mark_read_by(user)
    else
      Rails.logger.warn "Conversation does not respond to mark_read_by method"
    end
  rescue => e
    Rails.logger.error "Error marking conversation as read: #{e.message}"
    raise e
  end

  # ENHANCED: Safe message loading
  def safely_load_conversation_messages(conversation)
    return [] unless conversation
    
    conversation.messages
               .includes(:user)
               .chronological
               .limit(50)
  rescue => e
    Rails.logger.error "Error loading conversation messages: #{e.message}"
    []
  end

  # ENHANCED: Safe conversation update after message
  def safely_update_conversation_after_message(conversation)
    return unless conversation
    
    conversation.touch(:last_activity_at)
  rescue => e
    Rails.logger.error "Error updating conversation after message: #{e.message}"
  end

  # ENHANCED: Safe ActionCable broadcasting methods with comprehensive error handling
  def safely_broadcast_new_support_ticket(conversation)
    return unless conversation
    
    begin
      customer = safely_get_customer_from_conversation(conversation)
      package = safely_find_package_for_conversation(conversation)
      
      # Broadcast to support agents channel
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
          customer: safely_format_customer_data(customer),
          package: package ? {
            id: package.id,
            code: package.code,
            state: package.state
          } : nil,
          timestamp: Time.current.iso8601
        }
      )
      
      # Broadcast to customer's personal channel
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
      
      Rails.logger.info "📡 New support ticket broadcast sent for ticket #{conversation.ticket_id}"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast new support ticket: #{e.message}"
    end
  end

  def safely_broadcast_conversation_update(conversation, new_message)
    return unless conversation && new_message
    
    begin
      # Broadcast to conversation-specific channel
      ActionCable.server.broadcast(
        "conversation_#{conversation.id}",
        {
          type: 'conversation_updated',
          conversation_id: conversation.id,
          last_activity_at: conversation.last_activity_at&.iso8601,
          last_message: {
            id: new_message.id,
            content: truncate_message(new_message.content),
            created_at: new_message.created_at&.iso8601,
            from_support: new_message.from_support?,
            user_name: new_message.user&.display_name || 'Unknown'
          },
          timestamp: Time.current.iso8601
        }
      )
      
      # Safely broadcast to each participant's personal channel
      safely_broadcast_to_participants(conversation, new_message)
      
      Rails.logger.info "📡 Conversation update broadcast sent for conversation #{conversation.id}"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast conversation update: #{e.message}"
    end
  end

  def safely_broadcast_to_participants(conversation, new_message)
    return unless conversation && new_message
    
    conversation.conversation_participants.includes(:user).find_each do |participant|
      next unless participant.user
      next if participant.user == new_message.user # Don't notify sender
      
      begin
        unread_count = safely_calculate_unread_count(conversation, participant.user)
        
        ActionCable.server.broadcast(
          "user_messages_#{participant.user.id}",
          {
            type: 'conversation_activity',
            conversation_id: conversation.id,
            unread_count: unread_count,
            last_message: {
              content: truncate_message(new_message.content),
              from_support: new_message.from_support?,
              created_at: new_message.created_at&.iso8601
            },
            timestamp: Time.current.iso8601
          }
        )
      rescue => e
        Rails.logger.error "❌ Failed to broadcast to participant #{participant.user.id}: #{e.message}"
      end
    end
  rescue => e
    Rails.logger.error "❌ Error in safely_broadcast_to_participants: #{e.message}"
  end

  def broadcast_conversation_read_status(conversation, reader)
    return unless conversation && reader
    
    begin
      # Broadcast read status to conversation channel
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
      
      # Update unread count for the reader
      ActionCable.server.broadcast(
        "user_messages_#{reader.id}",
        {
          type: 'conversation_read_update',
          conversation_id: conversation.id,
          unread_count: 0,
          timestamp: Time.current.iso8601
        }
      )
      
      Rails.logger.info "📡 Conversation read status broadcast sent for conversation #{conversation.id}"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast read status: #{e.message}"
    end
  end

  def safely_broadcast_ticket_status_change(conversation, action, actor, system_message)
    return unless conversation && actor
    
    begin
      customer = safely_get_customer_from_conversation(conversation)
      assigned_agent = safely_get_assigned_agent_from_conversation(conversation)
      
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
          system_message: system_message ? safely_format_message(system_message) : nil,
          timestamp: Time.current.iso8601
        }
      )
      
      # Safely broadcast to other channels
      safely_broadcast_ticket_status_to_agents(conversation, action, customer, assigned_agent)
      safely_broadcast_ticket_status_to_customer(conversation, action, actor, customer)
      safely_broadcast_ticket_status_to_assigned_agent(conversation, action, actor, assigned_agent)
      
      Rails.logger.info "📡 Ticket status change broadcast sent for ticket #{conversation.ticket_id} (#{action})"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast ticket status change: #{e.message}"
    end
  end

  def safely_broadcast_ticket_status_to_agents(conversation, action, customer, assigned_agent)
    ActionCable.server.broadcast(
      "support_tickets",
      {
        type: 'ticket_status_updated',
        conversation_id: conversation.id,
        ticket_id: conversation.ticket_id,
        status: conversation.status,
        action: action,
        customer: safely_format_customer_data(customer),
        assigned_agent: safely_format_agent_data(assigned_agent),
        timestamp: Time.current.iso8601
      }
    )
  rescue => e
    Rails.logger.error "❌ Failed to broadcast to agents: #{e.message}"
  end

  def safely_broadcast_ticket_status_to_customer(conversation, action, actor, customer)
    return unless customer
    
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
  rescue => e
    Rails.logger.error "❌ Failed to broadcast to customer: #{e.message}"
  end

  def safely_broadcast_ticket_status_to_assigned_agent(conversation, action, actor, assigned_agent)
    return unless assigned_agent && assigned_agent != actor
    
    ActionCable.server.broadcast(
      "user_messages_#{assigned_agent.id}",
      {
        type: 'assigned_ticket_status_changed',
        conversation_id: conversation.id,
        ticket_id: conversation.ticket_id,
        status: conversation.status,
        action: action,
        timestamp: Time.current.iso8601
      }
    )
  rescue => e
    Rails.logger.error "❌ Failed to broadcast to assigned agent: #{e.message}"
  end

  def set_conversation
    @conversation = current_user.conversations.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error "Conversation #{params[:id]} not found for user #{current_user.id}"
    @conversation = nil
    render json: { success: false, message: 'Conversation not found' }, status: :not_found
  rescue => e
    Rails.logger.error "Error finding conversation #{params[:id]}: #{e.message}"
    @conversation = nil
    render json: { success: false, message: 'Error loading conversation' }, status: :internal_server_error
  end

  # ENHANCED: Safe package finding with comprehensive error handling
  def safely_find_package_for_ticket
    return nil unless params[:package_code].present? || params[:package_id].present?
    
    package = nil
    
    if params[:package_code].present?
      package = current_user.packages.find_by(code: params[:package_code])
      unless package
        Rails.logger.warn "Package not found with code: #{params[:package_code]} for user #{current_user.id}"
        raise ActiveRecord::RecordNotFound, 'Package not found'
      end
    elsif params[:package_id].present?
      package = current_user.packages.find_by(id: params[:package_id])
      unless package
        Rails.logger.warn "Package not found with id: #{params[:package_id]} for user #{current_user.id}"
        raise ActiveRecord::RecordNotFound, 'Package not found'
      end
    end
    
    Rails.logger.info "Found package: #{package.code}" if package
    package
  rescue ActiveRecord::RecordNotFound
    raise
  rescue => e
    Rails.logger.error "Error finding package for ticket: #{e.message}"
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
    Rails.logger.error "Error finding existing active ticket: #{e.message}"
    nil
  end

  # ENHANCED: Safe message metadata parsing
  def safely_parse_message_metadata(conversation)
    return {} unless conversation
    
    metadata = params[:metadata] || {}
    metadata = {} unless metadata.is_a?(Hash)
    
    # Safely add package code
    if params[:package_code].present?
      metadata[:package_code] = params[:package_code]
      safely_upgrade_conversation_to_package_inquiry(conversation, params[:package_code])
    end
    
    # Safely inherit package code from conversation
    if metadata[:package_code].blank?
      package = safely_find_package_for_conversation(conversation)
      if package
        metadata[:package_code] = package.code
        Rails.logger.info "Inherited package code from conversation context: #{package.code}"
      end
    end
    
    metadata
  rescue => e
    Rails.logger.error "Error parsing message metadata: #{e.message}"
    {}
  end

  def safely_upgrade_conversation_to_package_inquiry(conversation, package_code)
    return unless conversation&.support_ticket? && conversation.category == 'basic_inquiry'
    
    package = Package.find_by(code: package_code)
    if package && package.user == current_user
      conversation.metadata ||= {}
      conversation.metadata['package_id'] = package.id
      conversation.metadata['package_code'] = package.code
      conversation.metadata['category'] = 'package_inquiry'
      conversation.save!
      Rails.logger.info "Upgraded basic inquiry to package inquiry for package: #{package.code}"
    end
  rescue => e
    Rails.logger.error "Failed to upgrade conversation to package inquiry: #{e.message}"
  end

  def safely_update_support_ticket_status
    return unless @conversation&.support_ticket?
    
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
  rescue => e
    Rails.logger.error "Error updating support ticket status: #{e.message}"
  end

  # ENHANCED: Safe notification sending
  def safely_send_support_notifications(message)
    return unless message && @conversation
    
    Rails.logger.info "🔔 Creating support notifications for message #{message.id}"
    
    # Get participants to notify (exclude message sender)
    participants_to_notify = @conversation.conversation_participants
                                        .includes(:user)
                                        .where.not(user: message.user)
    
    Rails.logger.info "👥 Found #{participants_to_notify.size} participants to notify"
    
    participants_to_notify.find_each do |participant|
      next unless participant.user
      
      begin
        safely_create_notification_for_user(message, participant.user)
      rescue => e
        Rails.logger.error "❌ Failed to create notification for user #{participant.user.id}: #{e.message}"
      end
    end
  rescue => e
    Rails.logger.error "❌ Error in safely_send_support_notifications: #{e.message}"
  end

  # ENHANCED: Safe notification creation
  def safely_create_notification_for_user(message, recipient)
    return unless message && recipient
    
    Rails.logger.info "📝 Creating notification for user #{recipient.id} (#{recipient.email})"
    
    # SIMPLIFIED: Determine if user is support based on email only (most reliable)
    is_support_user = recipient.email&.include?('@glt.co.ke') || recipient.email&.include?('support@')
    is_customer_sender = !message.from_support?
    
    # Determine notification content
    if is_customer_sender && is_support_user
      # Customer to Support Agent
      title = "New message from #{message.user&.display_name || 'Customer'}"
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
    
    # Create notification with enhanced error handling
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
    
    # Send push notification safely
    safely_send_push_notification(notification, recipient)
    
    notification
  rescue => e
    Rails.logger.error "❌ Error creating notification for user #{recipient.id}: #{e.message}"
    nil
  end

  def safely_send_push_notification(notification, recipient)
    return unless notification && recipient
    
    if recipient.push_tokens.active.any?
      Rails.logger.info "📱 Sending push notification for notification #{notification.id}"
      
      begin
        PushNotificationService.new.send_immediate(notification)
        Rails.logger.info "✅ Push notification sent successfully"
      rescue => e
        Rails.logger.error "❌ Push notification failed: #{e.message}"
      end
    else
      Rails.logger.warn "⚠️ No push tokens found for user #{recipient.id}"
    end
  rescue => e
    Rails.logger.error "❌ Error in safely_send_push_notification: #{e.message}"
  end

  # ENHANCED: Safe user retrieval methods
  def safely_get_customer_from_conversation(conversation)
    return nil unless conversation
    
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
  rescue => e
    Rails.logger.error "Error getting customer from conversation: #{e.message}"
    nil
  end

  def safely_get_assigned_agent_from_conversation(conversation)
    return nil unless conversation&.support_ticket?
    
    agent_participant = conversation.conversation_participants
                                  .includes(:user)
                                  .find_by(role: 'agent')
    agent_participant&.user
  rescue => e
    Rails.logger.error "Error getting assigned agent from conversation: #{e.message}"
    nil
  end

  # ENHANCED: Safe formatting methods with comprehensive error handling
  def safely_format_customer_data(customer)
    return nil unless customer
    
    {
      id: customer.id,
      name: customer.display_name || customer.email || 'Unknown',
      email: customer.email,
      avatar_url: safely_get_avatar_url(customer)
    }
  rescue => e
    Rails.logger.error "Error formatting customer data: #{e.message}"
    {
      id: customer&.id,
      name: 'Unknown',
      email: customer&.email,
      avatar_url: nil
    }
  end

  def safely_format_agent_data(agent)
    return nil unless agent
    
    {
      id: agent.id,
      name: agent.display_name || agent.email || 'Unknown',
      email: agent.email,
      avatar_url: safely_get_avatar_url(agent)
    }
  rescue => e
    Rails.logger.error "Error formatting agent data: #{e.message}"
    {
      id: agent&.id,
      name: 'Unknown',
      email: agent&.email,
      avatar_url: nil
    }
  end

  def safely_get_avatar_url(user)
    return nil unless user
    
    if respond_to?(:avatar_api_url)
      avatar_api_url(user)
    else
      nil
    end
  rescue => e
    Rails.logger.error "Error getting avatar URL for user #{user.id}: #{e.message}"
    nil
  end

  # ENHANCED: Safe conversation formatting
  def safely_format_conversation_summary(conversation)
    return nil unless conversation
    
    last_message = safely_get_last_message(conversation)
    customer = safely_get_customer_from_conversation(conversation)
    assigned_agent = safely_get_assigned_agent_from_conversation(conversation)
    other_participant = safely_get_other_participant(conversation)

    status_display = safely_get_status_display(conversation)

    {
      id: conversation.id,
      conversation_type: conversation.conversation_type || 'unknown',
      title: conversation.title || 'Untitled Conversation',
      last_activity_at: conversation.last_activity_at,
      unread_count: safely_calculate_unread_count(conversation, current_user),
      status_display: status_display,
      ticket_id: conversation.ticket_id,
      status: conversation.status,
      category: conversation.category,
      priority: conversation.priority,
      customer: safely_format_customer_data(customer),
      assigned_agent: safely_format_agent_data(assigned_agent),
      other_participant: other_participant ? safely_format_customer_data(other_participant) : nil,
      last_message: last_message ? safely_format_last_message_summary(last_message) : nil,
      participants: safely_format_participants(conversation)
    }
  rescue => e
    Rails.logger.error "Error formatting conversation summary for conversation #{conversation.id}: #{e.message}"
    {
      id: conversation.id,
      conversation_type: conversation.conversation_type || 'unknown',
      title: conversation.title || 'Untitled Conversation',
      error: 'Failed to load conversation details'
    }
  end

  def safely_format_conversation_detail(conversation)
    return nil unless conversation
    
    base_summary = safely_format_conversation_summary(conversation)
    return base_summary if base_summary[:error]
    
    customer = safely_get_customer_from_conversation(conversation)
    assigned_agent = safely_get_assigned_agent_from_conversation(conversation)
    package = safely_find_package_for_conversation(conversation)
    
    additional_details = {
      metadata: conversation.metadata || {},
      created_at: conversation.created_at,
      updated_at: conversation.updated_at,
      escalated: conversation.metadata&.dig('escalated') || false,
      message_count: safely_get_message_count(conversation),
      customer: safely_format_customer_data(customer),
      assigned_agent: safely_format_agent_data(assigned_agent),
      package: safely_format_package_data(package)
    }

    base_summary.merge(additional_details)
  rescue => e
    Rails.logger.error "Error formatting conversation detail for conversation #{conversation.id}: #{e.message}"
    safely_format_conversation_summary(conversation)
  end

  def safely_format_message(message)
    return nil unless message
    
    {
      id: message.id,
      content: message.content || '',
      message_type: message.message_type || 'text',
      metadata: message.metadata || {},
      created_at: message.created_at,
      timestamp: safely_get_formatted_timestamp(message),
      is_system: message.is_system? || false,
      from_support: message.from_support? || false,
      user: safely_format_message_user(message.user)
    }
  rescue => e
    Rails.logger.error "Error formatting message #{message.id}: #{e.message}"
    {
      id: message.id,
      content: message.content || 'Error loading message',
      metadata: {},
      error: 'Failed to format message'
    }
  end

  def safely_format_message_user(user)
    return { id: nil, name: 'Unknown', role: 'unknown', avatar_url: nil } unless user
    
    {
      id: user.id,
      name: user.display_name || user.email || 'Unknown',
      role: (user.from_support? rescue false) ? 'support' : 'customer',
      avatar_url: safely_get_avatar_url(user)
    }
  rescue => e
    Rails.logger.error "Error formatting message user: #{e.message}"
    { id: user&.id, name: 'Unknown', role: 'unknown', avatar_url: nil }
  end

  # ENHANCED: Safe helper methods
  def safely_get_last_message(conversation)
    conversation.last_message
  rescue => e
    Rails.logger.error "Error getting last message: #{e.message}"
    nil
  end

  def safely_get_other_participant(conversation)
    return nil unless conversation&.direct_message?
    
    conversation.other_participant(current_user)
  rescue => e
    Rails.logger.error "Error getting other participant: #{e.message}"
    nil
  end

  def safely_get_status_display(conversation)
    case conversation.status
    when 'pending'
      'Ticket Pending'
    when 'in_progress'
      'Online'
    when 'closed'
      'Last seen recently'
    else
      'Online'
    end
  rescue => e
    Rails.logger.error "Error getting status display: #{e.message}"
    'Unknown'
  end

  def safely_calculate_unread_count(conversation, user)
    return 0 unless conversation && user
    
    if conversation.respond_to?(:unread_count_for)
      conversation.unread_count_for(user)
    else
      0
    end
  rescue => e
    Rails.logger.error "Error calculating unread count: #{e.message}"
    0
  end

  def safely_get_message_count(conversation)
    conversation.messages.count
  rescue => e
    Rails.logger.error "Error getting message count: #{e.message}"
    0
  end

  def safely_format_last_message_summary(message)
    return nil unless message
    
    {
      content: truncate_message(message.content),
      created_at: message.created_at,
      from_support: message.from_support? || false
    }
  rescue => e
    Rails.logger.error "Error formatting last message summary: #{e.message}"
    { content: 'Error loading message', created_at: nil, from_support: false }
  end

  def safely_format_participants(conversation)
    return [] unless conversation
    
    conversation.conversation_participants.includes(:user).map do |participant|
      next unless participant.user
      
      {
        user_id: participant.user.id,
        name: participant.user.display_name || participant.user.email || 'Unknown',
        role: participant.role || 'participant',
        joined_at: participant.joined_at,
        avatar_url: safely_get_avatar_url(participant.user)
      }
    end.compact
  rescue => e
    Rails.logger.error "Error formatting participants: #{e.message}"
    []
  end

  def safely_format_package_data(package)
    return nil unless package
    
    {
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
  rescue => e
    Rails.logger.error "Error formatting package data: #{e.message}"
    nil
  end

  def safely_get_formatted_timestamp(message)
    message.formatted_timestamp if message.respond_to?(:formatted_timestamp)
  rescue => e
    Rails.logger.error "Error getting formatted timestamp: #{e.message}"
    message.created_at&.strftime('%H:%M')
  end

  # ENHANCED: Safe package finding for conversation
  def safely_find_package_for_conversation(conversation)
    return nil unless conversation
    
    # Try package_id from conversation metadata
    if conversation.metadata&.dig('package_id')
      begin
        package = Package.find(conversation.metadata['package_id'])
        Rails.logger.debug "Found package from conversation metadata package_id: #{package.code}"
        return package
      rescue ActiveRecord::RecordNotFound
        Rails.logger.warn "Package not found for conversation metadata package_id: #{conversation.metadata['package_id']}"
      rescue => e
        Rails.logger.error "Error finding package by ID: #{e.message}"
      end
    end
    
    # Try package_code from conversation metadata
    if conversation.metadata&.dig('package_code')
      begin
        package = Package.find_by(code: conversation.metadata['package_code'])
        if package
          Rails.logger.debug "Found package from conversation metadata package_code: #{package.code}"
          return package
        else
          Rails.logger.warn "Package not found for conversation metadata package_code: #{conversation.metadata['package_code']}"
        end
      rescue => e
        Rails.logger.error "Error finding package by code: #{e.message}"
      end
    end
    
    # Try finding from message metadata
    begin
      message_with_package = conversation.messages
                                       .where("metadata->>'package_code' IS NOT NULL")
                                       .first
      if message_with_package&.metadata&.dig('package_code')
        package = Package.find_by(code: message_with_package.metadata['package_code'])
        if package
          Rails.logger.debug "Found package from message metadata: #{package.code}"
          return package
        end
      end
    rescue => e
      Rails.logger.error "Error finding package from message metadata: #{e.message}"
    end
    
    Rails.logger.debug "No package found for conversation #{conversation.id}"
    nil
  rescue => e
    Rails.logger.error "Error in safely_find_package_for_conversation: #{e.message}"
    nil
  end

  def truncate_message(content)
    return '' unless content
    content.length > 100 ? "#{content[0..97]}..." : content
  end
end
