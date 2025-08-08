# app/controllers/api/v1/admin/conversations_controller.rb
class Api::V1::Admin::ConversationsController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_admin_or_support!
  before_action :set_conversation, only: [:show, :assign_to_me, :transfer, :update_status]

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

    # Filter by assigned agent
    if params[:agent_id].present?
      @conversations = @conversations.joins(:conversation_participants)
                                   .where(conversation_participants: { 
                                     user_id: params[:agent_id], 
                                     role: 'agent' 
                                   })
    end

    # Filter unassigned tickets
    if params[:unassigned] == 'true'
      assigned_conversation_ids = ConversationParticipant.where(role: 'agent').pluck(:conversation_id)
      @conversations = @conversations.where.not(id: assigned_conversation_ids)
    end

    @conversations = @conversations.recent.limit(50)

    render json: {
      success: true,
      conversations: @conversations.map { |conv| format_admin_conversation(conv) },
      total_count: @conversations.count
    }
  end

  # GET /api/v1/admin/conversations/:id
  def show
    render json: {
      success: true,
      conversation: format_admin_conversation_detail(@conversation),
      customer_history: format_customer_history(@conversation.customer),
      messages: @conversation.messages.includes(:user).chronological.limit(100).map { |msg| format_message(msg) }
    }
  end

  # PATCH /api/v1/admin/conversations/:id/assign_to_me
  def assign_to_me
    # Remove existing agent if any
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
    @conversation.messages.create!(
      user: current_user,
      content: "Agent #{current_user.display_name} has been assigned to this ticket.",
      message_type: 'system',
      is_system: true
    )

    render json: {
      success: true,
      message: 'Conversation assigned successfully'
    }
  end

  # PATCH /api/v1/admin/conversations/:id/transfer
  def transfer
    new_agent = User.find(params[:agent_id])
    
    unless new_agent.has_role?(:support) || new_agent.has_role?(:admin)
      return render json: {
        success: false,
        message: 'Invalid agent specified'
      }, status: :unprocessable_entity
    end

    # Remove existing agent
    existing_agent = @conversation.conversation_participants.find_by(role: 'agent')
    existing_agent&.destroy

    # Add new agent
    @conversation.conversation_participants.create!(
      user: new_agent,
      role: 'agent',
      joined_at: Time.current
    )

    # Add system message
    @conversation.messages.create!(
      user: current_user,
      content: "Conversation transferred to #{new_agent.display_name}. Reason: #{params[:reason]}",
      message_type: 'system',
      is_system: true,
      metadata: {
        transfer_reason: params[:reason],
        transfer_notes: params[:notes],
        previous_agent: current_user.display_name
      }
    )

    render json: {
      success: true,
      message: 'Conversation transferred successfully'
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

    # Add system message
    @conversation.messages.create!(
      user: current_user,
      content: "Ticket status updated to: #{params[:status].humanize}",
      message_type: 'system',
      is_system: true
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
    unless current_user.has_role?(:admin) || current_user.has_role?(:support)
      render json: { 
        success: false, 
        message: 'Access denied. Admin or support role required.' 
      }, status: :forbidden
    end
  end

  def format_admin_conversation(conversation)
    customer = conversation.customer
    agent = conversation.assigned_agent
    last_message = conversation.last_message

    {
      id: conversation.id,
      ticket_id: conversation.ticket_id,
      title: conversation.title,
      status: conversation.status,
      category: conversation.category,
      priority: conversation.priority,
      created_at: conversation.created_at,
      last_activity_at: conversation.last_activity_at,
      
      customer: customer ? {
        id: customer.id,
        name: customer.display_name,
        email: customer.email
      } : nil,
      
      assigned_agent: agent ? {
        id: agent.id,
        name: agent.display_name,
        email: agent.email
      } : nil,
      
      last_message: last_message ? {
        content: last_message.content.truncate(100),
        created_at: last_message.created_at,
        from_support: last_message.from_support?
      } : nil,
      
      unread_count: conversation.messages.where(is_system: false).count
    }
  end

  def format_admin_conversation_detail(conversation)
    format_admin_conversation(conversation).merge({
      metadata: conversation.metadata,
      messages_count: conversation.messages.count,
      customer_messages_count: conversation.messages.joins(:user)
                                           .where(users: { id: conversation.customer&.id })
                                           .count
    })
  end

  def format_customer_history(customer)
    return nil unless customer

    previous_conversations = customer.conversations.support_tickets
                                   .where.not(id: @conversation.id)
                                   .recent
                                   .limit(5)

    {
      total_conversations: customer.conversations.support_tickets.count,
      previous_conversations: previous_conversations.map { |conv| format_admin_conversation(conv) },
      customer_since: customer.created_at,
      total_messages: Message.joins(:conversation)
                            .where(conversations: { id: customer.conversation_ids })
                            .where(user: customer)
                            .count
    }
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
end