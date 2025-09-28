# app/controllers/api/v1/conversations_controller.rb - Fixed with proper error handling

class Api::V1::ConversationsController < ApplicationController
  include AvatarHelper
  
  before_action :authenticate_user!
  before_action :set_conversation, only: [:show, :close, :reopen, :accept_ticket, :send_message]

  # GET /api/v1/conversations
  def index
    begin
      @conversations = current_user.conversations
                                  .includes(:conversation_participants, :users, messages: :user)
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
        conversations: @conversations.map { |conversation| safe_format_conversation_summary(conversation) }
      }, status: :ok
    rescue => e
      Rails.logger.error "Error in conversations#index: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render json: { 
        success: false, 
        message: 'Failed to load conversations',
        error: Rails.env.development? ? e.message : 'Internal error'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/conversations/:id
  def show
    begin
      # Mark as read with error handling
      begin
        @conversation.mark_read_by(current_user) if @conversation.respond_to?(:mark_read_by)
      rescue => e
        Rails.logger.warn "Failed to mark conversation as read: #{e.message}"
      end

      # Get messages with optimized includes
      @messages = @conversation.messages
                             .includes(:user)
                             .order(:created_at)
                             .limit(50)

      # Broadcast read status (non-blocking)
      begin
        broadcast_conversation_read_status(@conversation, current_user)
      rescue => e
        Rails.logger.warn "Failed to broadcast read status: #{e.message}"
      end

      render json: {
        success: true,
        conversation: safe_format_conversation_detail(@conversation),
        messages: @messages.map { |message| safe_format_message(message) }
      }, status: :ok
    rescue => e
      Rails.logger.error "Error in conversations#show: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render json: { 
        success: false, 
        message: 'Failed to load conversation',
        error: Rails.env.development? ? e.message : 'Internal error'
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/conversations/support_ticket
  def create_support_ticket
    Rails.logger.info "Creating support ticket with params: #{params.except(:controller, :action).inspect}"
    
    begin
      package = find_package_for_ticket
      existing_conversation = find_existing_active_ticket
      
      if existing_conversation
        Rails.logger.info "Found existing active ticket: #{existing_conversation.id}"
        return render json: {
          success: true,
          conversation: safe_format_conversation_detail(existing_conversation),
          conversation_id: existing_conversation.id,
          ticket_id: existing_conversation.ticket_id,
          message: 'Using existing support ticket'
        }, status: :ok
      end

      @conversation = Conversation.create_support_ticket(
        customer: current_user,
        category: params[:category] || 'general',
        package: package
      )

      if @conversation.persisted?
        Rails.logger.info "Created support ticket: #{@conversation.id}"
        
        # Non-blocking broadcast
        begin
          broadcast_new_support_ticket(@conversation)
        rescue => e
          Rails.logger.warn "Failed to broadcast new ticket: #{e.message}"
        end
        
        render json: {
          success: true,
          conversation: safe_format_conversation_detail(@conversation),
          conversation_id: @conversation.id,
          ticket_id: @conversation.ticket_id,
          message: 'Support ticket created successfully'
        }, status: :created
      else
        render json: { 
          success: false, 
          errors: @conversation.errors.full_messages 
        }, status: :unprocessable_entity
      end
      
    rescue => e
      Rails.logger.error "Error creating support ticket: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render json: { 
        success: false, 
        message: 'Failed to create support ticket',
        error: Rails.env.development? ? e.message : 'Internal error'
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/conversations/:id/send_message
  def send_message
    Rails.logger.info "Sending message to conversation #{params[:id]}"
    
    begin
      # Validate required parameters
      if params[:content].blank?
        return render json: { 
          success: false, 
          message: 'Message content is required' 
        }, status: :unprocessable_entity
      end

      # Build message with minimal metadata to avoid errors
      message_metadata = safe_parse_message_metadata(@conversation)
      
      message_params = {
        content: params[:content].to_s.strip,
        message_type: params[:message_type] || 'text',
        metadata: message_metadata
      }

      @message = @conversation.messages.build(message_params)
      @message.user = current_user

      if @message.save
        Rails.logger.info "Message saved successfully: #{@message.id}"
        
        # Update conversation (non-critical)
        begin
          @conversation.touch(:last_activity_at)
          update_support_ticket_status if @conversation.support_ticket?
        rescue => e
          Rails.logger.warn "Failed to update conversation: #{e.message}"
        end

        # Send notifications (non-blocking)
        begin
          if @conversation.support_ticket? && !@message.is_system?
            send_support_notifications(@message)
          end
        rescue => e
          Rails.logger.warn "Failed to send notifications: #{e.message}"
        end

        # Broadcast updates (non-blocking)
        begin
          broadcast_conversation_update(@conversation, @message)
        rescue => e
          Rails.logger.warn "Failed to broadcast update: #{e.message}"
        end

        # Return simplified response to avoid formatting errors
        render json: {
          success: true,
          message: safe_format_message(@message),
          conversation_id: @conversation.id,
          last_activity_at: @conversation.last_activity_at&.iso8601
        }, status: :ok
      else
        render json: { 
          success: false, 
          errors: @message.errors.full_messages 
        }, status: :unprocessable_entity
      end
      
    rescue => e
      Rails.logger.error "Error sending message: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render json: { 
        success: false, 
        message: 'Failed to send message',
        error: Rails.env.development? ? e.message : 'Internal error'
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
          conversation: safe_format_conversation_detail(@conversation),
          conversation_id: @conversation.id
        }, status: :ok
      else
        render json: { 
          success: true, 
          conversation: nil, 
          conversation_id: nil 
        }, status: :ok
      end
    rescue => e
      Rails.logger.error "Error getting active support: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render json: { 
        success: false, 
        message: 'Failed to get active support conversation',
        error: Rails.env.development? ? e.message : 'Internal error'
      }, status: :internal_server_error
    end
  end

  # PATCH /api/v1/conversations/:id/accept_ticket
  def accept_ticket
    unless @conversation.support_ticket?
      return render json: { 
        success: false, 
        message: 'Only support tickets can be accepted' 
      }, status: :unprocessable_entity
    end

    unless current_user.support_agent? || current_user.admin?
      return render json: { 
        success: false, 
        message: 'Only support staff can accept tickets' 
      }, status: :forbidden
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

      # Non-blocking broadcast
      begin
        broadcast_ticket_status_change(@conversation, 'accepted', current_user, system_message)
      rescue => e
        Rails.logger.warn "Failed to broadcast ticket acceptance: #{e.message}"
      end

      render json: { 
        success: true, 
        message: 'Support ticket accepted successfully' 
      }, status: :ok
    rescue => e
      Rails.logger.error "Error accepting ticket: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render json: { 
        success: false, 
        message: 'Failed to accept ticket',
        error: Rails.env.development? ? e.message : 'Internal error'
      }, status: :internal_server_error
    end
  end

  # PATCH /api/v1/conversations/:id/close
  def close
    unless @conversation.support_ticket?
      return render json: { 
        success: false, 
        message: 'Only support tickets can be closed' 
      }, status: :unprocessable_entity
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

      # Non-blocking broadcast
      begin
        broadcast_ticket_status_change(@conversation, 'closed', current_user, system_message)
      rescue => e
        Rails.logger.warn "Failed to broadcast ticket closure: #{e.message}"
      end

      render json: { 
        success: true, 
        message: 'Support ticket closed successfully' 
      }, status: :ok
    rescue => e
      Rails.logger.error "Error closing ticket: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render json: { 
        success: false, 
        message: 'Failed to close ticket',
        error: Rails.env.development? ? e.message : 'Internal error'
      }, status: :internal_server_error
    end
  end

  # PATCH /api/v1/conversations/:id/reopen
  def reopen
    unless @conversation.support_ticket?
      return render json: { 
        success: false, 
        message: 'Only support tickets can be reopened' 
      }, status: :unprocessable_entity
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

      # Non-blocking broadcast
      begin
        broadcast_ticket_status_change(@conversation, 'reopened', current_user, system_message)
      rescue => e
        Rails.logger.warn "Failed to broadcast ticket reopening: #{e.message}"
      end

      render json: { 
        success: true, 
        message: 'Support ticket reopened successfully' 
      }, status: :ok
    rescue => e
      Rails.logger.error "Error reopening ticket: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render json: { 
        success: false, 
        message: 'Failed to reopen ticket',
        error: Rails.env.development? ? e.message : 'Internal error'
      }, status: :internal_server_error
    end
  end

  private

  def set_conversation
    @conversation = current_user.conversations.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { 
      success: false, 
      message: 'Conversation not found' 
    }, status: :not_found
  end

  # SAFE: Simplified message metadata parsing
  def safe_parse_message_metadata(conversation)
    metadata = {}
    
    begin
      # Only add package code if it's provided and valid
      if params[:package_code].present?
        package = Package.find_by(code: params[:package_code])
        if package && package.user == current_user
          metadata[:package_code] = package.code
        end
      end
    rescue => e
      Rails.logger.warn "Failed to parse message metadata: #{e.message}"
    end
    
    metadata
  end

  # SAFE: Error-resistant conversation formatting
  def safe_format_conversation_summary(conversation)
    begin
      last_message = conversation.messages.last
      
      # Basic conversation data with fallbacks
      summary = {
        id: conversation.id,
        conversation_type: conversation.conversation_type || 'direct',
        title: conversation.title || 'Untitled Conversation',
        last_activity_at: conversation.last_activity_at&.iso8601,
        unread_count: 0,
        status: conversation.status || 'active',
        created_at: conversation.created_at&.iso8601
      }

      # Add unread count safely
      begin
        if conversation.respond_to?(:unread_count_for)
          summary[:unread_count] = conversation.unread_count_for(current_user) || 0
        end
      rescue => e
        Rails.logger.warn "Failed to get unread count: #{e.message}"
        summary[:unread_count] = 0
      end

      # Add support ticket specific data
      if conversation.support_ticket?
        summary.merge!(
          ticket_id: conversation.ticket_id,
          category: conversation.category,
          priority: conversation.priority || 'normal'
        )
      end

      # Add last message safely
      if last_message
        summary[:last_message] = {
          content: truncate_message(last_message.content),
          created_at: last_message.created_at&.iso8601,
          from_support: last_message.respond_to?(:from_support?) ? last_message.from_support? : false
        }
      end

      summary
    rescue => e
      Rails.logger.error "Error formatting conversation summary: #{e.message}"
      {
        id: conversation.id,
        conversation_type: 'unknown',
        title: 'Error Loading Conversation',
        error: 'Failed to format conversation'
      }
    end
  end

  # SAFE: Error-resistant detailed conversation formatting
  def safe_format_conversation_detail(conversation)
    begin
      # Start with safe summary
      detail = safe_format_conversation_summary(conversation)
      
      # Add additional safe details
      detail.merge!(
        metadata: conversation.metadata || {},
        updated_at: conversation.updated_at&.iso8601,
        message_count: conversation.messages.count || 0
      )

      # Add participants safely
      begin
        detail[:participants] = conversation.conversation_participants.includes(:user).map do |participant|
          {
            user_id: participant.user.id,
            name: participant.user.display_name || 'Unknown User',
            role: participant.role || 'participant',
            joined_at: participant.joined_at&.iso8601
          }
        end
      rescue => e
        Rails.logger.warn "Failed to format participants: #{e.message}"
        detail[:participants] = []
      end

      detail
    rescue => e
      Rails.logger.error "Error formatting conversation detail: #{e.message}"
      {
        id: conversation.id,
        title: 'Error Loading Conversation Details',
        error: 'Failed to format conversation details'
      }
    end
  end

  # SAFE: Error-resistant message formatting
  def safe_format_message(message)
    begin
      {
        id: message.id,
        content: message.content || '',
        message_type: message.message_type || 'text',
        metadata: message.metadata || {},
        created_at: message.created_at&.iso8601,
        is_system: message.respond_to?(:is_system?) ? message.is_system? : false,
        from_support: message.respond_to?(:from_support?) ? message.from_support? : false,
        user: {
          id: message.user.id,
          name: message.user.display_name || 'Unknown User'
        }
      }
    rescue => e
      Rails.logger.error "Error formatting message: #{e.message}"
      {
        id: message.id,
        content: 'Error loading message',
        error: 'Failed to format message'
      }
    end
  end

  # SIMPLIFIED: Package finding with error handling
  def find_package_for_ticket
    return nil unless params[:package_code].present? || params[:package_id].present?
    
    begin
      if params[:package_code].present?
        package = current_user.packages.find_by(code: params[:package_code])
        unless package
          Rails.logger.warn "Package not found with code: #{params[:package_code]}"
          return nil
        end
        return package
      elsif params[:package_id].present?
        package = current_user.packages.find_by(id: params[:package_id])
        unless package
          Rails.logger.warn "Package not found with id: #{params[:package_id]}"
          return nil
        end
        return package
      end
    rescue => e
      Rails.logger.error "Error finding package: #{e.message}"
      return nil
    end
    
    nil
  end

  def find_existing_active_ticket
    begin
      Conversation.joins(:conversation_participants)
                  .where(conversation_participants: { user_id: current_user.id })
                  .support_tickets
                  .where("metadata->>'status' IN (?)", ['pending', 'in_progress'])
                  .where('conversations.created_at > ?', 24.hours.ago)
                  .first
    rescue => e
      Rails.logger.warn "Error finding existing ticket: #{e.message}"
      nil
    end
  end

  def update_support_ticket_status
    return unless @conversation.support_ticket?
    return unless @conversation.status == 'created'
    
    begin
      @conversation.update_support_status('pending')
      
      @conversation.messages.create!(
        user: current_user,
        content: "Support ticket ##{@conversation.ticket_id} has been created and is pending review.",
        message_type: 'system',
        is_system: true,
        metadata: { type: 'ticket_created' }
      )
    rescue => e
      Rails.logger.warn "Failed to update support ticket status: #{e.message}"
    end
  end

  # SIMPLIFIED: Notification creation
  def send_support_notifications(message)
    return unless @conversation.support_ticket?
    
    begin
      Rails.logger.info "Creating support notifications for message #{message.id}"
      
      participants_to_notify = @conversation.conversation_participants
                                           .includes(:user)
                                           .where.not(user: message.user)
      
      participants_to_notify.each do |participant|
        begin
          create_notification_for_user(message, participant.user)
        rescue => e
          Rails.logger.warn "Failed to create notification for user #{participant.user.id}: #{e.message}"
        end
      end
    rescue => e
      Rails.logger.warn "Failed to send support notifications: #{e.message}"
    end
  end

  def create_notification_for_user(message, recipient)
    begin
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
          ticket_id: @conversation.ticket_id
        }
      )
      
      # Send push notification
      if recipient.push_tokens.active.any?
        begin
          PushNotificationService.new.send_immediate(notification)
        rescue => e
          Rails.logger.warn "Push notification failed: #{e.message}"
        end
      end
    rescue => e
      Rails.logger.warn "Failed to create notification: #{e.message}"
    end
  end

  # SAFE: Broadcasting methods with error handling
  def broadcast_new_support_ticket(conversation)
    ActionCable.server.broadcast(
      "support_tickets",
      {
        type: 'new_support_ticket',
        conversation_id: conversation.id,
        ticket_id: conversation.ticket_id,
        status: conversation.status,
        timestamp: Time.current.iso8601
      }
    )
  rescue => e
    Rails.logger.warn "Failed to broadcast new support ticket: #{e.message}"
  end

  def broadcast_conversation_update(conversation, new_message)
    ActionCable.server.broadcast(
      "conversation_#{conversation.id}",
      {
        type: 'conversation_updated',
        conversation_id: conversation.id,
        message_id: new_message.id,
        timestamp: Time.current.iso8601
      }
    )
  rescue => e
    Rails.logger.warn "Failed to broadcast conversation update: #{e.message}"
  end

  def broadcast_conversation_read_status(conversation, reader)
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
    Rails.logger.warn "Failed to broadcast read status: #{e.message}"
  end

  def broadcast_ticket_status_change(conversation, action, actor, system_message)
    ActionCable.server.broadcast(
      "conversation_#{conversation.id}",
      {
        type: 'ticket_status_changed',
        conversation_id: conversation.id,
        action: action,
        status: conversation.status,
        timestamp: Time.current.iso8601
      }
    )
  rescue => e
    Rails.logger.warn "Failed to broadcast ticket status change: #{e.message}"
  end

  def truncate_message(content)
    return '' unless content
    content.length > 100 ? "#{content[0..97]}..." : content
  end
end