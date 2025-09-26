# app/controllers/api/v1/conversations_controller.rb
class Api::V1::ConversationsController < ApplicationController
  before_action :authenticate_user!
  # CHANGED: set_conversation now correctly finds conversations for any participant
  before_action :set_conversation, only: [:show, :close, :reopen, :accept_ticket, :send_message]

  # GET /api/v1/conversations
  # No major changes needed here, this is a read-only action.
  def index
    @conversations = current_user.conversations
                                .includes(:users, :last_message) # Eager load last message
                                .recent
                                .page(params[:page]).per(20) # Use a pagination gem like kaminari

    render json: {
      success: true,
      conversations: @conversations.map { |convo| format_conversation_summary(convo) }
    }
  end

  # GET /api/v1/conversations/:id
  def show
    @conversation.mark_read_by(current_user)
    @messages = @conversation.messages.includes(:user).chronological.limit(50)

    render json: {
      success: true,
      conversation: format_conversation_detail(@conversation),
      messages: @messages.map { |message| format_message(message) }
    }
  end

  # POST /api/v1/conversations/support_ticket
  def create_support_ticket
    # This entire block is wrapped in a transaction and rescue block
    # to ensure atomicity and prevent 500 errors.
    begin
      package = find_package_for_user(params)
      return if performed? # Stop if find_package_for_user rendered an error

      # Check for existing conversation
      existing_conversation = current_user.conversations.support_tickets
                                          .active_support.where('created_at > ?', 24.hours.ago)
                                          .first
      if existing_conversation
        return render json: {
          success: true,
          conversation: format_conversation_detail(existing_conversation),
          message: 'Using existing active support ticket.'
        }
      end

      # The Conversation.create_support_ticket can raise errors, so we catch them.
      @conversation = Conversation.create_support_ticket(
        customer: current_user,
        category: params[:category] || 'general',
        package: package
      )

      render json: {
        success: true,
        conversation: format_conversation_detail(@conversation),
        message: 'Support ticket created successfully.'
      }, status: :created

    # ADDED: Catch specific validation errors
    rescue ActiveRecord::RecordInvalid => e
      render json: { success: false, message: "Validation failed: #{e.message}" }, status: :unprocessable_entity
    # ADDED: Catch any other unexpected error
    rescue => e
      Rails.logger.error "Failed to create support ticket: #{e.message}"
      render json: { success: false, message: 'An unexpected error occurred. Please try again.' }, status: :internal_server_error
    end
  end

  # POST /api/v1/conversations/:id/messages
  def send_message
    @message = @conversation.messages.new(message_params)
    @message.user = current_user

    if @message.save
      render json: {
        success: true,
        message: format_message(@message)
      }
    else
      render json: {
        success: false,
        errors: @message.errors.full_messages
      }, status: :unprocessable_entity
    end
  end

  # GET /api/v1/conversations/active_support
  def active_support
    @conversation = current_user.conversations.support_tickets.active_support.recent.first
    if @conversation
      render json: { success: true, conversation: format_conversation_detail(@conversation) }
    else
      render json: { success: true, conversation: nil }
    end
  end

  # PATCH /api/v1/conversations/:id/accept_ticket
  def accept_ticket
    authorize_support_action!
    return if performed?

    begin
      @conversation.update_support_status('in_progress')
      # Use `find_or_create_by` to be idempotent
      @conversation.conversation_participants.find_or_create_by!(user: current_user) do |p|
        p.role = 'agent'
      end
      # Use non-bang create and check for errors
      create_system_message("Support ticket has been accepted by #{current_user.display_name}.")
      render json: { success: true, message: 'Support ticket accepted.' }
    rescue => e
      render_error("Failed to accept ticket: #{e.message}")
    end
  end

  # PATCH /api/v1/conversations/:id/close
  def close
    authorize_support_action!
    return if performed?

    begin
      @conversation.update_support_status('closed')
      create_system_message('This support ticket has been closed.')
      render json: { success: true, message: 'Support ticket closed successfully.' }
    rescue => e
      render_error("Failed to close ticket: #{e.message}")
    end
  end

  # PATCH /api/v1/conversations/:id/reopen
  def reopen
    authorize_support_action!
    return if performed?

    begin
      @conversation.update_support_status('in_progress')
      create_system_message('This support ticket has been reopened.')
      render json: { success: true, message: 'Support ticket reopened successfully.' }
    rescue => e
      render_error("Failed to reopen ticket: #{e.message}")
    end
  end

  private

  def set_conversation
    # CHANGED: This now correctly finds any conversation the user is a part of.
    @conversation = Conversation.joins(:conversation_participants)
                                .find_by(
                                  id: params[:id],
                                  conversation_participants: { user_id: current_user.id }
                                )
    unless @conversation
      render json: { success: false, message: 'Conversation not found or access denied.' }, status: :not_found
    end
  end

  def message_params
    params.permit(:content, :message_type, metadata: {})
  end

  # HELPER: To find package safely
  def find_package_for_user(params)
    return nil unless params[:package_id].present?
    
    package = current_user.packages.find_by(id: params[:package_id])
    unless package
      render json: { success: false, message: 'Package not found.' }, status: :not_found
    end
    package
  end
  
  # HELPER: To authorize support staff actions
  def authorize_support_action!
    unless @conversation.support_ticket?
      return render json: { success: false, message: 'This action is only for support tickets.' }, status: :unprocessable_entity
    end
    unless current_user.support_staff?
      return render json: { success: false, message: 'You are not authorized to perform this action.' }, status: :forbidden
    end
  end

  # HELPER: To create system messages safely
  def create_system_message(content)
    @conversation.messages.create(
      user: current_user,
      content: content,
      message_type: 'system',
      is_system: true
    )
  end

  # HELPER: To render a generic error
  def render_error(message, status = :internal_server_error)
    Rails.logger.error message
    render json: { success: false, message: message }, status: status
  end

  # --- FORMATTING HELPERS ---

  def format_conversation_summary(conversation)
    {
      id: conversation.id,
      conversation_type: conversation.conversation_type,
      title: conversation.title,
      last_activity_at: conversation.last_activity_at,
      unread_count: conversation.unread_count_for(current_user),
      status: conversation.support_ticket? ? conversation.status : 'active',
      # FIXED: Use safe navigation `&.` to prevent errors if last_message is nil
      last_message_preview: conversation.last_message&.content&.truncate(50),
      # ADDED: More details about the other participant for direct messages
      participant: format_participant_info(conversation)
    }
  end

  def format_conversation_detail(conversation)
    format_conversation_summary(conversation).merge({
      metadata: conversation.metadata,
      created_at: conversation.created_at,
      # FIXED: Use safe navigation `&.` to prevent NoMethodError if package is deleted
      package: conversation.package ? {
        id: conversation.package.id,
        code: conversation.package.code,
        state_display: conversation.package.state_display
      } : nil
    })
  end

  def format_message(message)
    {
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      created_at: message.created_at,
      is_system: message.is_system?,
      from_support: message.from_support?,
      user: {
        id: message.user.id,
        name: message.user.display_name,
        # FIXED: Avatar URL with safe navigation
        avatar_url: message.user.avatar.attached? ? url_for(message.user.avatar) : nil
      }
    }
  end

  def format_participant_info(conversation)
    return nil unless conversation.direct_message?
    
    other_user = conversation.other_participant(current_user)
    # FIXED: Check if other_user exists
    other_user ? {
      id: other_user.id,
      name: other_user.display_name,
      avatar_url: other_user.avatar.attached? ? url_for(other_user.avatar) : nil
    } : { name: "Deleted User" }
  end
end
