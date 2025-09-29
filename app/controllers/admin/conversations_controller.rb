# app/controllers/admin/conversations_controller.rb - FIXED pagination
class Admin::ConversationsController < AdminController
  before_action :set_conversation, only: [:show, :assign_to_me, :update_status]
  
  # GET /admin/conversations
  def index
    @conversations = Conversation.support_tickets
                                .includes(:conversation_participants, :users, :messages)
                                .recent
                                .limit(20)  # FIXED: Removed .page() - use limit instead
                                .offset((params[:page].to_i - 1) * 20)
    
    # Apply filters
    @conversations = @conversations.where("metadata->>'status' = ?", params[:status]) if params[:status].present?
    @conversations = @conversations.where("metadata->>'priority' = ?", params[:priority]) if params[:priority].present?
    
    @stats = {
      total: Conversation.support_tickets.count,
      pending: Conversation.support_tickets.where("metadata->>'status' = 'pending'").count,
      in_progress: Conversation.support_tickets.where("metadata->>'status' = 'in_progress'").count,
      resolved: Conversation.support_tickets.where("metadata->>'status' = 'resolved'").count
    }
  end
  
  # GET /admin/conversations/:id
  def show
    @messages = @conversation.messages.includes(:user).chronological.limit(100)
    @customer = @conversation.customer
    @agent = @conversation.assigned_agent
  end
  
  # GET /admin/conversations/test
  def test
    @conversations = Conversation.support_tickets.recent.limit(10)
  end
  
  # POST /admin/conversations/test_message
  def test_message
    conversation = Conversation.find(params[:conversation_id])
    
    message = conversation.messages.create!(
      user: current_user,
      content: params[:content],
      message_type: 'text'
    )
    
    # Broadcast immediately
    ActionCable.server.broadcast(
      "conversation_#{conversation.id}",
      {
        type: 'new_message',
        conversation_id: conversation.id,
        message: {
          id: message.id,
          content: message.content,
          user: {
            id: current_user.id,
            name: current_user.display_name || current_user.email
          },
          created_at: message.created_at.iso8601
        }
      }
    )
    
    flash[:success] = 'Test message sent successfully'
    redirect_to test_admin_conversations_path
  rescue => e
    flash[:error] = "Failed to send message: #{e.message}"
    redirect_to test_admin_conversations_path
  end
  
  # PATCH /admin/conversations/:id/assign_to_me
  def assign_to_me
    existing_agent = @conversation.conversation_participants.find_by(role: 'agent')
    existing_agent&.destroy
    
    @conversation.conversation_participants.create!(
      user: current_user,
      role: 'agent',
      joined_at: Time.current
    )
    
    @conversation.update_support_status('assigned')
    
    flash[:success] = 'Conversation assigned to you'
    redirect_to admin_conversation_path(@conversation)
  end
  
  # PATCH /admin/conversations/:id/update_status
  def update_status
    valid_statuses = %w[pending assigned in_progress waiting_customer resolved closed]
    
    unless valid_statuses.include?(params[:status])
      flash[:error] = 'Invalid status'
      redirect_to admin_conversation_path(@conversation) and return
    end
    
    @conversation.update_support_status(params[:status])
    
    ActionCable.server.broadcast(
      "conversation_#{@conversation.id}",
      {
        type: 'ticket_status_changed',
        conversation_id: @conversation.id,
        status: params[:status],
        timestamp: Time.current.iso8601
      }
    )
    
    flash[:success] = "Status updated to: #{params[:status].humanize}"
    redirect_to admin_conversation_path(@conversation)
  end
  
  private
  
  def set_conversation
    @conversation = Conversation.find(params[:id])
  end
end