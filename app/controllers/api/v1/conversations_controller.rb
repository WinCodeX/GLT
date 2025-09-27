# app/controllers/api/v1/conversations_controller.rb - FIXED VERSION
class Api::V1::ConversationsController < ApplicationController
  include AvatarHelper  # FIXED: Include avatar helper for R2 support
  
  before_action :authenticate_user!
  before_action :set_conversation, only: [:show, :close, :reopen, :accept_ticket, :send_message]

  # GET /api/v1/conversations
  def index
    @conversations = current_user.conversations
                                .includes(:conversation_participants, :users, :messages)
                                .recent

    # Filter by type if specified
    if params[:type].present?
      case params[:type]
      when 'support'
        @conversations = @conversations.support_tickets
      when 'direct'
        @conversations = @conversations.direct_messages
      end
    end

    # Filter by status for support tickets
    if params[:status].present? && params[:type] == 'support'
      @conversations = @conversations.where("metadata->>'status' = ?", params[:status])
    end

    # Add pagination
    page = [params[:page].to_i, 1].max
    @conversations = @conversations.limit(20).offset((page - 1) * 20)

    render json: {
      success: true,
      conversations: @conversations.map do |conversation|
        format_conversation_summary(conversation)
      end
    }
  rescue => e
    Rails.logger.error "Error in conversations#index: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { 
      success: false, 
      message: 'Failed to load conversations' 
    }, status: :internal_server_error
  end

  # GET /api/v1/conversations/:id
  def show
    begin
      # Mark as read for current user
      @conversation.mark_read_by(current_user)

      # Get recent messages (last 50)
      @messages = @conversation.messages
                              .includes(:user)
                              .chronological
                              .limit(50)

      render json: {
        success: true,
        conversation: format_conversation_detail(@conversation),
        messages: @messages.map { |message| format_message(message) }
      }
    rescue => e
      Rails.logger.error "Error in conversations#show: #{e.message}"
      render json: { 
        success: false, 
        message: 'Failed to load conversation' 
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/conversations/support_ticket
  def create_support_ticket
    Rails.logger.info "Creating support ticket with params: #{params.inspect}"
    
    begin
      package = find_package_for_ticket
      
      # Check for existing active support conversation
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

      # Create new conversation
      @conversation = Conversation.create_support_ticket(
        customer: current_user,
        category: params[:category] || 'general',
        package: package
      )

      if @conversation.persisted?
        Rails.logger.info "Created support ticket: #{@conversation.id}"
        render json: {
          success: true,
          conversation: format_conversation_detail(@conversation),
          conversation_id: @conversation.id,
          ticket_id: @conversation.ticket_id,
          message: 'Support ticket created successfully'
        }, status: :created
      else
        Rails.logger.error "Failed to create conversation: #{@conversation.errors.full_messages}"
        render json: {
          success: false,
          errors: @conversation.errors.full_messages
        }, status: :unprocessable_entity
      end
      
    rescue => e
      Rails.logger.error "Error creating support ticket: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to create support ticket',
        error: e.message
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/conversations/:id/send_message
  def send_message
    Rails.logger.info "Sending message to conversation #{params[:id]} with content: #{params[:content]}"
    Rails.logger.info "Message metadata: #{params[:metadata]}"
    
    begin
      # FIXED: Enhanced metadata parsing to include conversation package context
      message_metadata = parse_message_metadata(@conversation)
      
      message_params = {
        content: params[:content],
        message_type: params[:message_type] || 'text',
        metadata: message_metadata
      }

      @message = @conversation.messages.build(message_params)
      @message.user = current_user

      if @message.save
        # Update conversation last activity
        @conversation.touch(:last_activity_at)
        
        # Handle support ticket status updates
        update_support_ticket_status if @conversation.support_ticket?

        Rails.logger.info "Message saved successfully: #{@message.id} with metadata: #{@message.metadata}"
        
        # FIXED: Send push notifications to relevant participants
        send_message_notifications(@conversation, @message)
        
        render json: {
          success: true,
          message: format_message(@message),
          conversation: format_conversation_detail(@conversation)
        }
      else
        Rails.logger.error "Failed to save message: #{@message.errors.full_messages}"
        render json: {
          success: false,
          errors: @message.errors.full_messages
        }, status: :unprocessable_entity
      end
      
    rescue => e
      Rails.logger.error "Error sending message: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to send message',
        error: e.message
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
          conversation: format_conversation_detail(@conversation),
          conversation_id: @conversation.id
        }
      else
        render json: {
          success: true,
          conversation: nil,
          conversation_id: nil
        }
      end
    rescue => e
      Rails.logger.error "Error getting active support: #{e.message}"
      render json: {
        success: false,
        message: 'Failed to get active support conversation'
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
      
      # Add support agent as participant if not already
      unless @conversation.conversation_participants.exists?(user: current_user)
        @conversation.conversation_participants.create!(
          user: current_user,
          role: 'agent',
          joined_at: Time.current
        )
      end
      
      # Add system message
      @conversation.messages.create!(
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

      render json: {
        success: true,
        message: 'Support ticket accepted successfully'
      }
    rescue => e
      Rails.logger.error "Error accepting ticket: #{e.message}"
      render json: {
        success: false,
        message: 'Failed to accept ticket'
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
      
      # Add system message
      @conversation.messages.create!(
        user: current_user,
        content: 'This support ticket has been closed.',
        message_type: 'system',
        is_system: true,
        metadata: { 
          type: 'ticket_closed',
          closed_by: current_user.id
        }
      )

      render json: {
        success: true,
        message: 'Support ticket closed successfully'
      }
    rescue => e
      Rails.logger.error "Error closing ticket: #{e.message}"
      render json: {
        success: false,
        message: 'Failed to close ticket'
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
      
      # Add system message
      @conversation.messages.create!(
        user: current_user,
        content: 'This support ticket has been reopened.',
        message_type: 'system',
        is_system: true,
        metadata: { 
          type: 'ticket_reopened',
          reopened_by: current_user.id
        }
      )

      render json: {
        success: true,
        message: 'Support ticket reopened successfully'
      }
    rescue => e
      Rails.logger.error "Error reopening ticket: #{e.message}"
      render json: {
        success: false,
        message: 'Failed to reopen ticket'
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

  # FIXED: Enhanced metadata parsing to preserve package context and upgrade basic inquiries
  def parse_message_metadata(conversation)
    metadata = params[:metadata] || {}
    
    # Ensure metadata is a hash
    metadata = {} unless metadata.is_a?(Hash)
    
    # Add package code from request params if present
    if params[:package_code].present?
      metadata[:package_code] = params[:package_code]
      
      # FIXED: If this is a basic inquiry conversation but user is sending package metadata,
      # upgrade it to package inquiry and associate the package
      if conversation.support_ticket? && conversation.category == 'basic_inquiry'
        begin
          package = Package.find_by(code: params[:package_code])
          if package && package.user == current_user
            # Upgrade conversation to package inquiry
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
    
    # FIXED: If no package_code in request but conversation has package context, inherit it
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
    # If this is the first user message, set status to pending
    if @conversation.status == 'created'
      @conversation.update_support_status('pending')
      
      # Add system message about ticket creation
      @conversation.messages.create!(
        user: current_user,
        content: "Support ticket ##{@conversation.ticket_id} has been created and is pending review.",
        message_type: 'system',
        is_system: true,
        metadata: { type: 'ticket_created' }
      )
    end
  end

  # FIXED: Properly extract customer information
  def get_customer_from_conversation(conversation)
    # For support tickets, find the customer participant
    if conversation.support_ticket?
      customer_participant = conversation.conversation_participants
                                       .includes(:user)
                                       .find_by(role: 'customer')
      return customer_participant&.user
    end
    
    # For direct messages, find the other participant
    if conversation.direct_message?
      return conversation.other_participant(current_user)
    end
    
    nil
  end

  # FIXED: Properly extract assigned agent information
  def get_assigned_agent_from_conversation(conversation)
    return nil unless conversation.support_ticket?
    
    agent_participant = conversation.conversation_participants
                                  .includes(:user)
                                  .find_by(role: 'agent')
    agent_participant&.user
  end

  # FIXED: Format customer data consistently with R2 avatar support
  def format_customer_data(customer)
    return nil unless customer
    
    {
      id: customer.id,
      name: customer.display_name,
      email: customer.email,
      avatar_url: avatar_api_url(customer)  # FIXED: Use avatar helper instead of direct Active Storage
    }
  end

  # FIXED: Format agent data consistently with R2 avatar support
  def format_agent_data(agent)
    return nil unless agent
    
    {
      id: agent.id,
      name: agent.display_name,
      email: agent.email,
      avatar_url: avatar_api_url(agent)  # FIXED: Use avatar helper instead of direct Active Storage
    }
  end

  def format_conversation_summary(conversation)
    last_message = conversation.last_message
    
    # FIXED: Properly get customer and agent data
    customer = get_customer_from_conversation(conversation)
    assigned_agent = get_assigned_agent_from_conversation(conversation)
    other_participant = conversation.other_participant(current_user) if conversation.direct_message?

    # Determine conversation status for display
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
      
      # Support ticket specific fields
      ticket_id: conversation.ticket_id,
      status: conversation.status,
      category: conversation.category,
      priority: conversation.priority,
      
      # FIXED: Proper customer data formatting
      customer: format_customer_data(customer),
      
      # FIXED: Proper assigned agent data formatting
      assigned_agent: format_agent_data(assigned_agent),
      
      # Direct message specific fields
      other_participant: other_participant ? format_customer_data(other_participant) : nil,
      
      # Last message preview
      last_message: last_message ? {
        content: truncate_message(last_message.content),
        created_at: last_message.created_at,
        from_support: last_message.from_support?
      } : nil,
      
      # Participants
      participants: conversation.conversation_participants.includes(:user).map do |participant|
        {
          user_id: participant.user.id,
          name: participant.user.display_name,
          role: participant.role,
          joined_at: participant.joined_at,
          avatar_url: avatar_api_url(participant.user)  # FIXED: Use avatar helper
        }
      end
    }
  rescue => e
    Rails.logger.error "Error formatting conversation summary: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    {
      id: conversation.id,
      conversation_type: conversation.conversation_type,
      title: conversation.title || 'Untitled Conversation',
      error: 'Failed to load conversation details'
    }
  end

  def format_conversation_detail(conversation)
    base_summary = format_conversation_summary(conversation)
    
    # FIXED: Get customer and agent properly
    customer = get_customer_from_conversation(conversation)
    assigned_agent = get_assigned_agent_from_conversation(conversation)
    
    additional_details = {
      metadata: conversation.metadata || {},
      created_at: conversation.created_at,
      updated_at: conversation.updated_at,
      escalated: conversation.metadata&.dig('escalated') || false,
      message_count: conversation.messages.count,
      
      # FIXED: Ensure customer data is always included
      customer: format_customer_data(customer),
      assigned_agent: format_agent_data(assigned_agent),
      
      # Package information if this is a package inquiry
      package: nil
    }

    # FIXED: Try to get package information from multiple sources
    package = find_package_for_conversation(conversation)
    
    # Format package data if found
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
    Rails.logger.error e.backtrace.join("\n")
    format_conversation_summary(conversation)
  end

  # FIXED: Enhanced message formatting to include package metadata
  def format_message(message)
    {
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      # FIXED: Ensure metadata is always included and properly formatted
      metadata: message.metadata || {},
      created_at: message.created_at,
      timestamp: message.formatted_timestamp,
      is_system: message.is_system?,
      from_support: message.from_support?,
      user: {
        id: message.user.id,
        name: message.user.display_name,
        role: message.from_support? ? 'support' : 'customer',
        avatar_url: avatar_api_url(message.user)  # FIXED: Use avatar helper
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
    
    # First try from conversation metadata package_id
    if conversation.metadata&.dig('package_id')
      begin
        package = Package.find(conversation.metadata['package_id'])
        Rails.logger.debug "Found package from conversation metadata package_id: #{package.code}"
        return package
      rescue ActiveRecord::RecordNotFound
        Rails.logger.warn "Package not found for conversation metadata package_id: #{conversation.metadata['package_id']}"
      end
    end
    
    # Then try from conversation metadata package_code
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
        Rails.logger.warn "Error finding package by conversation metadata package_code #{conversation.metadata['package_code']}: #{e.message}"
      end
    end
    
    # Finally try from any message metadata in this conversation
    begin
      message_with_package = conversation.messages
                                       .where("metadata->>'package_code' IS NOT NULL")
                                       .first
      if message_with_package&.metadata&.dig('package_code')
        package = Package.find_by(code: message_with_package.metadata['package_code'])
        if package
          Rails.logger.debug "Found package from message metadata: #{package.code}"
          return package
        else
          Rails.logger.warn "Package not found for message metadata package_code: #{message_with_package.metadata['package_code']}"
        end
      end
    rescue => e
      Rails.logger.warn "Error finding package from message metadata: #{e.message}"
    end
    
    # No package found
    Rails.logger.debug "No package found for conversation #{conversation.id}"
    nil
  end

  def truncate_message(content)
    return '' unless content
    content.length > 100 ? "#{content[0..97]}..." : content
  end
end