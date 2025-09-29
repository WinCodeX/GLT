# app/controllers/api/v1/admin/conversations_controller.rb (FIXED)
class Api::V1::Admin::ConversationsController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_admin_or_support!
  before_action :set_conversation, only: [:show, :assign_to_me, :transfer, :update_status, :send_message]

  # GET /api/v1/admin/conversations
  def index
    @conversations = Conversation.support_tickets
                                .includes(:conversation_participants, :users, :messages)

    # Filter by status
    if params[:status].present?
      @conversations = @conversations.where("metadata->>'status' = ?", params[:status])
    end

    # Filter by priority
    if params[:priority].present?
      @conversations = @conversations.where("metadata->>'priority' = ?", params[:priority])
    end

    # Filter unassigned tickets
    if params[:unassigned] == 'true'
      assigned_conversation_ids = ConversationParticipant.where(role: 'agent').pluck(:conversation_id)
      @conversations = @conversations.where.not(id: assigned_conversation_ids)
    end

    @conversations = @conversations.recent.limit(50)

    render json: {
      success: true,
      conversations: @conversations.map { |conv| format_conversation(conv) }
    }
  end

  # GET /api/v1/admin/conversations/:id
  def show
    @messages = @conversation.messages.includes(:user).chronological.limit(100)

    render json: {
      success: true,
      conversation: format_conversation_detail(@conversation),
      messages: @messages.map { |msg| format_message(msg) }
    }
  end

  # POST /api/v1/admin/conversations/:id/send_message
  def send_message
    @message = @conversation.messages.create!(
      user: current_user,
      content: params[:content],
      message_type: params[:message_type] || 'text'
    )

    @conversation.touch(:last_activity_at)

    # Broadcast immediately
    ActionCable.server.broadcast(
      "conversation_#{@conversation.id}",
      {
        type: 'new_message',
        conversation_id: @conversation.id,
        message: format_message(@message),
        timestamp: Time.current.iso8601
      }
    )

    # Also broadcast to support dashboard
    ActionCable.server.broadcast(
      "support_dashboard",
      {
        type: 'new_message',
        conversation_id: @conversation.id,
        ticket_id: @conversation.current_ticket_id || @conversation.ticket_id,
        message: {
          content: @message.content.to_s.truncate(50),
          from_support: @message.from_support?,
          created_at: @message.created_at.iso8601
        },
        timestamp: Time.current.iso8601
      }
    )

    render json: {
      success: true,
      message: format_message(@message)
    }
  rescue => e
    Rails.logger.error "Error sending message: #{e.message}"
    render json: {
      success: false,
      message: 'Failed to send message',
      error: e.message
    }, status: :unprocessable_entity
  end

  # PATCH /api/v1/admin/conversations/:id/assign_to_me
  def assign_to_me
    # Remove existing agent
    existing_agent = @conversation.conversation_participants.find_by(role: 'agent')
    existing_agent&.destroy

    # Add current user as agent
    @conversation.conversation_participants.create!(
      user: current_user,
      role: 'agent',
      joined_at: Time.current
    )

    @conversation.update_support_status('assigned')

    # Add system message
    system_message = @conversation.messages.create!(
      user: current_user,
      content: "Agent #{current_user.display_name} has been assigned to this ticket.",
      message_type: 'system',
      is_system: true
    )

    # Broadcast to conversation
    ActionCable.server.broadcast(
      "conversation_#{@conversation.id}",
      {
        type: 'agent_assigned',
        conversation_id: @conversation.id,
        agent: {
          id: current_user.id,
          name: current_user.display_name
        },
        system_message: format_message(system_message),
        timestamp: Time.current.iso8601
      }
    )

    render json: {
      success: true,
      message: 'Conversation assigned successfully'
    }
  end

  # PATCH /api/v1/admin/conversations/:id/status
  def update_status
    valid_statuses = %w[pending assigned in_progress waiting_customer resolved closed]
    
    unless valid_statuses.include?(params[:status])
      return render json: {
        success: false,
        message: 'Invalid status'
      }, status: :unprocessable_entity
    end

    @conversation.update_support_status(params[:status])

    # System message
    system_message = @conversation.messages.create!(
      user: current_user,
      content: "Ticket status updated to: #{params[:status].humanize}",
      message_type: 'system',
      is_system: true
    )

    # Broadcast status change
    ActionCable.server.broadcast(
      "conversation_#{@conversation.id}",
      {
        type: 'ticket_status_changed',
        conversation_id: @conversation.id,
        status: params[:status],
        system_message: format_message(system_message),
        timestamp: Time.current.iso8601
      }
    )

    # Broadcast to support dashboard
    ActionCable.server.broadcast(
      "support_dashboard",
      {
        type: 'ticket_status_update',
        ticket_id: @conversation.id,
        status: params[:status],
        timestamp: Time.current.iso8601
      }
    )

    render json: {
      success: true,
      message: 'Status updated successfully'
    }
  end

  private

  def set_conversation
    @conversation = Conversation.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { 
      success: false, 
      message: 'Conversation not found' 
    }, status: :not_found
  end

  def ensure_admin_or_support!
    unless current_user.admin? || current_user.has_role?(:support)
      render json: { 
        success: false, 
        message: 'Access denied' 
      }, status: :forbidden
    end
  end

  def format_conversation(conversation)
    {
      id: conversation.id,
      ticket_id: conversation.ticket_id || conversation.current_ticket_id,
      title: conversation.title,
      status: conversation.status,
      category: conversation.category,
      priority: conversation.priority,
      created_at: conversation.created_at,
      last_activity_at: conversation.last_activity_at,
      customer: conversation.customer ? {
        id: conversation.customer.id,
        name: conversation.customer.display_name,
        email: conversation.customer.email
      } : nil,
      assigned_agent: conversation.assigned_agent ? {
        id: conversation.assigned_agent.id,
        name: conversation.assigned_agent.display_name
      } : nil,
      last_message: conversation.last_message ? {
        content: conversation.last_message.content.to_s.truncate(100),
        created_at: conversation.last_message.created_at
      } : nil
    }
  end

  def format_conversation_detail(conversation)
    format_conversation(conversation).merge({
      metadata: conversation.metadata || {},
      messages_count: conversation.messages.count
    })
  end

  def format_message(message)
    {
      id: message.id,
      content: message.content || '',
      message_type: message.message_type || 'text',
      created_at: message.created_at,
      is_system: message.is_system? || false,
      from_support: message.from_support? || false,
      user: {
        id: message.user.id,
        name: message.user.display_name || message.user.email
      }
    }
  end
end