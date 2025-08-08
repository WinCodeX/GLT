# app/controllers/api/v1/messages_controller.rb
class Api::V1::MessagesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation

  # GET /api/v1/conversations/:conversation_id/messages
  def index
    # Get messages with pagination
    page = params[:page]&.to_i || 1
    per_page = 50
    
    @messages = @conversation.messages
                            .includes(:user)
                            .chronological
                            .limit(per_page)
                            .offset((page - 1) * per_page)

    total_messages = @conversation.messages.count
    total_pages = (total_messages / per_page.to_f).ceil

    render json: {
      success: true,
      messages: @messages.map { |message| format_message(message) },
      pagination: {
        current_page: page,
        total_pages: total_pages,
        total_count: total_messages,
        has_more: page < total_pages
      }
    }
  end

  # POST /api/v1/conversations/:conversation_id/messages
  def create
    @message = @conversation.messages.build(message_params)
    @message.user = current_user

    if @message.save
      render json: {
        success: true,
        message: format_message(@message)
      }, status: :created
    else
      render json: {
        success: false,
        errors: @message.errors.full_messages
      }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/conversations/:conversation_id/messages/mark_read
  def mark_read
    @conversation.mark_read_by(current_user)
    
    render json: {
      success: true,
      message: 'Conversation marked as read'
    }
  end

  private

  def set_conversation
    @conversation = current_user.conversations.find(params[:conversation_id])
  rescue ActiveRecord::RecordNotFound
    render json: { 
      success: false, 
      message: 'Conversation not found' 
    }, status: :not_found
  end

  def message_params
    params.require(:message).permit(:content, :message_type, metadata: {})
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