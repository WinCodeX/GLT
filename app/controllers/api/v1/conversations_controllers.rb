# app/controllers/api/v1/conversations_controller.rb
class Api::V1::ConversationsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation, only: [:show, :close, :reopen]

  # GET /api/v1/conversations
  # Returns all conversations for the current user
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
    @conversations = @conversations.limit(20).offset((params[:page]&.to_i || 1 - 1) * 20)

    render json: {
      success: true,
      conversations: @conversations.map do |conversation|
        format_conversation_summary(conversation)
      end
    }
  end

  # GET /api/v1/conversations/:id
  # Returns full conversation with messages
  def show
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
  end

  # POST /api/v1/conversations/support_ticket
  # Creates a new support ticket
  def create_support_ticket
    package = nil
    if params[:package_id].present?
      package = Package.find_by(id: params[:package_id])
      unless package
        return render json: { 
          success: false, 
          message: 'Package not found' 
        }, status: :not_found
      end
    end

    @conversation = Conversation.create_support_ticket(
      customer: current_user,
      category: params[:category] || 'general',
      package: package
    )

    if @conversation.persisted?
      render json: {
        success: true,
        conversation: format_conversation_detail(@conversation),
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
  end

  # GET /api/v1/conversations/active_support
  # Returns active support conversation for current user
  def active_support
    @conversation = current_user.conversations
                               .support_tickets
                               .active_support
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
  end

  # PATCH /api/v1/conversations/:id/close
  # Closes a support ticket
  def close
    unless @conversation.support_ticket?
      return render json: { 
        success: false, 
        message: 'Only support tickets can be closed' 
      }, status: :unprocessable_entity
    end

    @conversation.update_support_status('closed')
    
    # Add system message
    @conversation.messages.create!(
      user: current_user,
      content: 'This support ticket has been closed.',
      message_type: 'system',
      is_system: true
    )

    render json: {
      success: true,
      message: 'Support ticket closed successfully'
    }
  end

  # PATCH /api/v1/conversations/:id/reopen
  # Reopens a closed support ticket
  def reopen
    unless @conversation.support_ticket?
      return render json: { 
        success: false, 
        message: 'Only support tickets can be reopened' 
      }, status: :unprocessable_entity
    end

    @conversation.update_support_status('in_progress')
    
    # Add system message
    @conversation.messages.create!(
      user: current_user,
      content: 'This support ticket has been reopened.',
      message_type: 'system',
      is_system: true
    )

    render json: {
      success: true,
      message: 'Support ticket reopened successfully'
    }
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

  def format_conversation_summary(conversation)
    last_message = conversation.last_message
    other_participant = conversation.other_participant(current_user) if conversation.direct_message?

    {
      id: conversation.id,
      conversation_type: conversation.conversation_type,
      title: conversation.title,
      last_activity_at: conversation.last_activity_at,
      unread_count: conversation.unread_count_for(current_user),
      
      # Support ticket specific fields
      ticket_id: conversation.ticket_id,
      status: conversation.status,
      category: conversation.category,
      priority: conversation.priority,
      
      # Direct message specific fields
      other_participant: other_participant ? {
        id: other_participant.id,
        name: other_participant.display_name,
        avatar_url: other_participant.avatar.present? ? url_for(other_participant.avatar) : nil
      } : nil,
      
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
          joined_at: participant.joined_at
        }
      end
    }
  end

  def format_conversation_detail(conversation)
    format_conversation_summary(conversation).merge({
      metadata: conversation.metadata,
      created_at: conversation.created_at,
      updated_at: conversation.updated_at
    })
  end

  def format_message(message)
    {
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      metadata: message.metadata,
      created_at: message.created_at,
      timestamp: message.formatted_timestamp,
      is_system: message.is_system?,
      from_support: message.from_support?,
      user: {
        id: message.user.id,
        name: message.user.display_name,
        role: message.from_support? ? 'support' : 'customer'
      }
    }
  end

  def truncate_message(content)
    content.length > 100 ? "#{content[0..97]}..." : content
  end
end