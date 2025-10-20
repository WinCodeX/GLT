class Api::V1::SupportController < ApplicationController
  include AvatarHelper
  
  before_action :authenticate_user!
  before_action :ensure_support_access!
  before_action :set_conversation, only: [:assign_ticket, :escalate_ticket, :add_note, :update_priority]

  # GET /api/v1/support/dashboard
  def dashboard
    begin
      stats = calculate_dashboard_stats
      recent_activity = get_recent_activity
      agent_stats = get_agent_performance_stats

      render json: {
        success: true,
        data: {
          stats: stats,
          recent_activity: recent_activity,
          agent_performance: agent_stats,
          current_agent: format_agent_info(current_user)
        }
      }
    rescue => e
      Rails.logger.error "Error loading support dashboard: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load dashboard data',
        error: e.message
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/support/tickets
  def tickets
    begin
      Rails.logger.info "📋 Loading tickets for support user: #{current_user.id} (#{current_user.display_name})"
      Rails.logger.info "User roles: #{current_user.roles.pluck(:name).join(', ')}"
      
      tickets_query = build_tickets_query
      tickets_query = apply_ticket_filters(tickets_query)
      
      page = [params[:page].to_i, 1].max
      limit = [params[:limit].to_i, 50].max.clamp(1, 100)
      
      Rails.logger.info "Fetching tickets - Page: #{page}, Limit: #{limit}"
      
      tickets = tickets_query.includes(:conversation_participants, :users, :messages)
                            .limit(limit)
                            .offset((page - 1) * limit)
      
      total_count = tickets_query.count
      
      Rails.logger.info "Found #{total_count} total tickets, returning #{tickets.count} for this page"
      
      render json: {
        success: true,
        data: {
          tickets: tickets.map { |ticket| format_support_ticket(ticket) },
          pagination: {
            current_page: page,
            total_pages: (total_count.to_f / limit).ceil,
            total_count: total_count,
            per_page: limit
          },
          filters_applied: extract_applied_filters
        }
      }
    rescue => e
      Rails.logger.error "❌ Error loading support tickets: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load support tickets',
        error: e.message
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/support/my_tickets
  def my_tickets
    begin
      Rails.logger.info "📋 Loading my tickets for agent: #{current_user.id}"
      
      # Get tickets where current user is assigned as agent
      my_tickets = Conversation.where(conversation_type: 'support_ticket')
                              .joins(:conversation_participants)
                              .where(conversation_participants: { role: 'agent', user_id: current_user.id })
                              .includes(:users, :messages)
                              .order(updated_at: :desc)
                              .limit(50)

      Rails.logger.info "Found #{my_tickets.count} assigned tickets"

      render json: {
        success: true,
        data: {
          tickets: my_tickets.map { |ticket| format_support_ticket(ticket) },
          agent_stats: get_agent_personal_stats
        }
      }
    rescue => e
      Rails.logger.error "Error loading agent tickets: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load your tickets',
        error: e.message
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/support/tickets/:id/assign
  def assign_ticket
    begin
      agent_id = params[:agent_id]
      
      if agent_id.blank?
        return render json: {
          success: false,
          message: 'Agent ID is required'
        }, status: :unprocessable_entity
      end

      agent = User.joins(:roles).where(roles: { name: 'support' }).find(agent_id)
      
      Rails.logger.info "Assigning ticket #{@conversation.id} to agent #{agent.id} (#{agent.display_name})"
      
      # Remove existing agent assignment
      existing_agent = @conversation.conversation_participants.find_by(role: 'agent')
      existing_agent&.destroy

      # Assign new agent
      @conversation.conversation_participants.create!(
        user: agent,
        role: 'agent',
        joined_at: Time.current
      )

      # Update conversation status
      current_metadata = @conversation.metadata || {}
      @conversation.metadata = current_metadata.merge('status' => 'assigned')
      @conversation.save!

      # Create system message
      system_message = @conversation.messages.create!(
        user: current_user,
        content: "Ticket assigned to #{agent.display_name} by #{current_user.display_name}",
        message_type: 'system',
        is_system: true,
        metadata: {
          type: 'ticket_assigned',
          assigned_to: agent.id,
          assigned_by: current_user.id
        }
      )

      broadcast_agent_assignment(agent)
      broadcast_system_message(system_message)
      broadcast_dashboard_stats_update

      render json: {
        success: true,
        message: 'Ticket assigned successfully',
        data: {
          assigned_agent: format_agent_info(agent),
          ticket: format_support_ticket(@conversation)
        }
      }
    rescue ActiveRecord::RecordNotFound
      render json: {
        success: false,
        message: 'Agent not found'
      }, status: :not_found
    rescue => e
      Rails.logger.error "Error assigning ticket: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to assign ticket',
        error: e.message
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/support/tickets/:id/escalate
  def escalate_ticket
    begin
      escalation_reason = params[:reason]
      escalate_to = params[:escalate_to]
      
      current_metadata = @conversation.metadata || {}
      @conversation.metadata = current_metadata.merge(
        'priority' => 'high',
        'escalated' => true,
        'escalation_reason' => escalation_reason,
        'escalated_to' => escalate_to,
        'escalated_by' => current_user.id,
        'escalated_at' => Time.current.iso8601
      )
      @conversation.save!

      system_message = @conversation.messages.create!(
        user: current_user,
        content: "Ticket escalated to #{escalate_to} team. Reason: #{escalation_reason}",
        message_type: 'system',
        is_system: true,
        metadata: {
          type: 'ticket_escalated',
          escalation_reason: escalation_reason,
          escalated_to: escalate_to,
          escalated_by: current_user.id
        }
      )

      broadcast_ticket_escalated(escalate_to, escalation_reason)
      broadcast_system_message(system_message)
      broadcast_dashboard_stats_update

      render json: {
        success: true,
        message: 'Ticket escalated successfully',
        data: {
          ticket: format_support_ticket(@conversation)
        }
      }
    rescue => e
      Rails.logger.error "Error escalating ticket: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to escalate ticket',
        error: e.message
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/support/tickets/:id/note
  def add_note
    begin
      note_content = params[:note]
      note_type = params[:note_type] || 'internal'
      
      if note_content.blank?
        return render json: {
          success: false,
          message: 'Note content is required'
        }, status: :unprocessable_entity
      end

      note = @conversation.messages.create!(
        user: current_user,
        content: note_content,
        message_type: 'system',
        is_system: true,
        metadata: {
          type: 'support_note',
          note_type: note_type,
          added_by: current_user.id,
          visibility: note_type
        }
      )

      broadcast_system_message(note)

      render json: {
        success: true,
        message: 'Note added successfully',
        data: {
          note: format_message(note)
        }
      }
    rescue => e
      Rails.logger.error "Error adding note: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to add note',
        error: e.message
      }, status: :internal_server_error
    end
  end

  # PATCH /api/v1/support/tickets/:id/priority
  def update_priority
    begin
      new_priority = params[:priority]
      
      unless %w[low normal high urgent].include?(new_priority)
        return render json: {
          success: false,
          message: 'Invalid priority level'
        }, status: :unprocessable_entity
      end

      old_priority = @conversation.metadata&.dig('priority') || 'normal'
      current_metadata = @conversation.metadata || {}
      @conversation.metadata = current_metadata.merge(
        'priority' => new_priority,
        'priority_updated_by' => current_user.id,
        'priority_updated_at' => Time.current.iso8601
      )
      @conversation.save!

      system_message = @conversation.messages.create!(
        user: current_user,
        content: "Priority updated from #{old_priority} to #{new_priority}",
        message_type: 'system',
        is_system: true,
        metadata: {
          type: 'priority_updated',
          old_priority: old_priority,
          new_priority: new_priority,
          updated_by: current_user.id
        }
      )

      broadcast_ticket_status_update
      broadcast_system_message(system_message)
      broadcast_dashboard_stats_update

      render json: {
        success: true,
        message: 'Priority updated successfully',
        data: {
          ticket: format_support_ticket(@conversation)
        }
      }
    rescue => e
      Rails.logger.error "Error updating priority: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to update priority',
        error: e.message
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/support/agents
  def agents
    begin
      agents = User.joins(:roles)
                  .where(roles: { name: 'support' })
                  .includes(:conversation_participants)
                  .order(:first_name, :last_name)

      agents_data = agents.map do |agent|
        agent_tickets = Conversation.where(conversation_type: 'support_ticket')
                                   .joins(:conversation_participants)
                                   .where(conversation_participants: { role: 'agent', user_id: agent.id })
        
        format_agent_info(agent).merge(
          current_workload: agent_tickets.where("conversations.metadata->>'status' IN (?)", ['assigned', 'in_progress']).count,
          performance_stats: get_agent_performance_stats(agent)
        )
      end

      render json: {
        success: true,
        data: {
          agents: agents_data
        }
      }
    rescue => e
      Rails.logger.error "Error loading agents: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load agents',
        error: e.message
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/support/bulk_actions
  def bulk_actions
    begin
      action = params[:action]
      ticket_ids = params[:ticket_ids] || []
      
      if ticket_ids.empty?
        return render json: {
          success: false,
          message: 'No tickets selected'
        }, status: :unprocessable_entity
      end

      results = perform_bulk_action(action, ticket_ids)
      broadcast_dashboard_stats_update
      
      render json: {
        success: true,
        message: "Bulk action '#{action}' completed",
        data: results
      }
    rescue => e
      Rails.logger.error "Error performing bulk action: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to perform bulk action',
        error: e.message
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/support/stats
  def stats
    begin
      time_range = params[:time_range] || '7d'
      stats = calculate_detailed_stats(time_range)
      
      render json: {
        success: true,
        data: stats
      }
    rescue => e
      Rails.logger.error "Error loading stats: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load statistics',
        error: e.message
      }, status: :internal_server_error
    end
  end

  private

  def set_conversation
    @conversation = Conversation.where(conversation_type: 'support_ticket').find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: {
      success: false,
      message: 'Ticket not found'
    }, status: :not_found
  end

  def ensure_support_access!
    unless current_user.has_role?(:support) || current_user.has_role?(:admin)
      Rails.logger.warn "Access denied for user #{current_user.id} - missing support role"
      render json: {
        success: false,
        message: 'Access denied. Support role required.'
      }, status: :forbidden
    end
  end

  def build_tickets_query
    # ALL support staff can see ALL support tickets
    # This is the key fix - support staff need to see unassigned tickets to claim them
    Conversation.where(conversation_type: 'support_ticket')
                .includes(:conversation_participants, :users, :messages)
                .order(updated_at: :desc)
  end

  def apply_ticket_filters(query)
    # Status filter
    if params[:status].present?
      query = query.where("conversations.metadata->>'status' = ?", params[:status])
    end
    
    # Priority filter
    if params[:priority].present?
      query = query.where("conversations.metadata->>'priority' = ?", params[:priority])
    end
    
    # Category filter
    if params[:category].present?
      query = query.where("conversations.metadata->>'category' = ?", params[:category])
    end

    # Agent filter - show only tickets assigned to specific agent
    if params[:agent_id].present?
      query = query.joins(:conversation_participants)
                  .where(conversation_participants: { user_id: params[:agent_id], role: 'agent' })
    end

    # Unassigned filter - show only unassigned tickets
    if params[:unassigned] == 'true'
      subquery = ConversationParticipant.where(role: 'agent')
                                        .where('conversation_participants.conversation_id = conversations.id')
                                        .select('1')
      query = query.where.not(id: Conversation.where('EXISTS (?)', subquery))
    end

    # Date filters
    if params[:created_after].present?
      query = query.where('conversations.created_at >= ?', params[:created_after])
    end
    
    if params[:created_before].present?
      query = query.where('conversations.created_at <= ?', params[:created_before])
    end

    # Search filter
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      query = query.left_joins(:users)
                  .where(
                    "conversations.title ILIKE ? OR 
                     users.first_name ILIKE ? OR 
                     users.last_name ILIKE ? OR 
                     users.email ILIKE ? OR
                     conversations.metadata->>'ticket_id' ILIKE ?",
                    search_term, search_term, search_term, search_term, search_term
                  )
                  .distinct
    end

    query
  end

  def extract_applied_filters
    filters = {}
    filters[:status] = params[:status] if params[:status].present?
    filters[:priority] = params[:priority] if params[:priority].present?
    filters[:category] = params[:category] if params[:category].present?
    filters[:agent_id] = params[:agent_id] if params[:agent_id].present?
    filters[:unassigned] = params[:unassigned] if params[:unassigned].present?
    filters[:search] = params[:search] if params[:search].present?
    
    if params[:created_after].present? || params[:created_before].present?
      filters[:date_range] = {}
      filters[:date_range][:after] = params[:created_after] if params[:created_after].present?
      filters[:date_range][:before] = params[:created_before] if params[:created_before].present?
    end
    
    filters
  end

  def get_customer_from_conversation(conversation)
    # Find the customer participant (the one who initiated the conversation)
    customer_participant = conversation.conversation_participants.find { |p| p.role == 'customer' }
    
    # If no customer role, find the first non-support user
    if customer_participant.nil?
      non_support_users = conversation.users.reject { |u| u.has_role?(:support) || u.has_role?(:admin) }
      return non_support_users.first
    end
    
    customer_participant&.user
  end

  def get_assigned_agent_from_conversation(conversation)
    # Find the agent participant
    agent_participant = conversation.conversation_participants.find { |p| p.role == 'agent' }
    agent_participant&.user
  end

  def get_last_message(conversation)
    conversation.messages.where.not(is_system: true).order(created_at: :desc).first
  end

  def calculate_unread_count(conversation, user)
    conversation.messages
                .where.not(user: user)
                .where(read_at: nil)
                .where.not(is_system: true)
                .count
  end

  def broadcast_agent_assignment(agent)
    ActionCable.server.broadcast(
      "support_dashboard",
      {
        type: 'agent_assignment_update',
        ticket_id: @conversation.id,
        agent: {
          id: agent.id,
          name: agent.display_name,
          email: agent.email
        },
        timestamp: Time.current.iso8601
      }
    )

    ActionCable.server.broadcast(
      "conversation_#{@conversation.id}",
      {
        type: 'conversation_updated',
        conversation_id: @conversation.id,
        assigned_agent: {
          id: agent.id,
          name: agent.display_name,
          email: agent.email
        },
        status: 'assigned',
        timestamp: Time.current.iso8601
      }
    )
    
    Rails.logger.info "✅ Agent assignment broadcast to dashboard and conversation #{@conversation.id}"
  end

  def broadcast_ticket_status_update
    status = @conversation.metadata&.dig('status') || 'pending'
    
    ActionCable.server.broadcast(
      "support_dashboard",
      {
        type: 'ticket_status_update',
        ticket_id: @conversation.id,
        status: status,
        timestamp: Time.current.iso8601
      }
    )

    ActionCable.server.broadcast(
      "conversation_#{@conversation.id}",
      {
        type: 'ticket_status_changed',
        conversation_id: @conversation.id,
        new_status: status,
        timestamp: Time.current.iso8601
      }
    )
    
    Rails.logger.info "✅ Status update broadcast to dashboard: #{status}"
  end

  def broadcast_ticket_escalated(escalate_to, reason)
    ActionCable.server.broadcast(
      "support_dashboard",
      {
        type: 'ticket_escalated',
        ticket_id: @conversation.id,
        escalated_to: escalate_to,
        reason: reason,
        timestamp: Time.current.iso8601
      }
    )

    ActionCable.server.broadcast(
      "conversation_#{@conversation.id}",
      {
        type: 'ticket_escalated',
        conversation_id: @conversation.id,
        escalated_to: escalate_to,
        timestamp: Time.current.iso8601
      }
    )
    
    Rails.logger.info "✅ Escalation broadcast to dashboard"
  end

  def broadcast_system_message(message)
    formatted_message = {
      id: message.id,
      content: message.content,
      created_at: message.created_at.iso8601,
      timestamp: message.created_at.strftime('%H:%M'),
      is_system: true,
      from_support: true,
      message_type: 'system',
      delivered_at: message.delivered_at&.iso8601,
      read_at: message.read_at&.iso8601,
      user: {
        id: message.user.id,
        name: message.user.display_name,
        role: message.user.roles.first&.name || 'user'
      },
      metadata: message.metadata || {}
    }

    ActionCable.server.broadcast(
      "conversation_#{@conversation.id}",
      {
        type: 'new_message',
        conversation_id: @conversation.id,
        message: formatted_message,
        timestamp: Time.current.iso8601
      }
    )
    
    Rails.logger.info "✅ System message broadcast to conversation #{@conversation.id}"
  end

  def broadcast_dashboard_stats_update
    stats = calculate_dashboard_stats

    ActionCable.server.broadcast(
      "support_dashboard",
      {
        type: 'dashboard_stats_update',
        stats: stats,
        timestamp: Time.current.iso8601
      }
    )
    
    Rails.logger.info "✅ Dashboard stats broadcast"
  end

  def calculate_dashboard_stats
    all_support_tickets = Conversation.where(conversation_type: 'support_ticket')
    
    {
      total_tickets: all_support_tickets.count,
      pending_tickets: all_support_tickets.where("conversations.metadata->>'status' = ? OR conversations.metadata->>'status' IS NULL", 'pending').count,
      in_progress_tickets: all_support_tickets.where("conversations.metadata->>'status' = ?", 'in_progress').count,
      assigned_tickets: all_support_tickets.where("conversations.metadata->>'status' = ?", 'assigned').count,
      resolved_today: all_support_tickets.where("conversations.metadata->>'status' = ?", 'resolved')
                                        .where('conversations.updated_at >= ?', Time.current.beginning_of_day).count,
      avg_response_time: calculate_avg_response_time,
      satisfaction_score: calculate_satisfaction_score,
      tickets_by_priority: {
        high: all_support_tickets.where("conversations.metadata->>'priority' = ?", 'high').count,
        normal: all_support_tickets.where("conversations.metadata->>'priority' = ? OR conversations.metadata->>'priority' IS NULL", 'normal').count,
        low: all_support_tickets.where("conversations.metadata->>'priority' = ?", 'low').count,
        urgent: all_support_tickets.where("conversations.metadata->>'priority' = ?", 'urgent').count
      }
    }
  end

  def get_recent_activity
    recent_tickets = Conversation.where(conversation_type: 'support_ticket')
                                .includes(:users, :messages)
                                .where('conversations.updated_at >= ?', 24.hours.ago)
                                .order('conversations.updated_at DESC')
                                .limit(10)

    recent_tickets.map do |ticket|
      {
        ticket_id: ticket.metadata&.dig('ticket_id') || "T-#{ticket.id}",
        customer_name: get_customer_from_conversation(ticket)&.display_name || 'Unknown',
        action: determine_last_action(ticket),
        timestamp: ticket.updated_at,
        agent: get_assigned_agent_from_conversation(ticket)&.display_name
      }
    end
  end

  def get_agent_performance_stats(agent = nil)
    target_agent = agent || current_user
    
    agent_tickets = Conversation.where(conversation_type: 'support_ticket')
                                .joins(:conversation_participants)
                                .where(conversation_participants: { role: 'agent', user_id: target_agent.id })
    
    {
      tickets_resolved_today: agent_tickets.where("conversations.metadata->>'status' = ?", 'resolved')
                                          .where('conversations.updated_at >= ?', Time.current.beginning_of_day)
                                          .count,
      avg_resolution_time: calculate_agent_avg_resolution_time(target_agent),
      active_tickets: agent_tickets.where("conversations.metadata->>'status' IN (?)", ['assigned', 'in_progress']).count,
      satisfaction_rating: calculate_agent_satisfaction(target_agent)
    }
  end

  def get_agent_personal_stats
    get_agent_performance_stats(current_user)
  end

  def format_support_ticket(conversation)
    customer = get_customer_from_conversation(conversation)
    assigned_agent = get_assigned_agent_from_conversation(conversation)
    last_msg = get_last_message(conversation)
    
    # Default status to 'pending' if not set
    status = conversation.metadata&.dig('status') || 'pending'
    
    {
      id: conversation.id,
      ticket_id: conversation.metadata&.dig('ticket_id') || "T-#{conversation.id}",
      title: conversation.title || 'Support Ticket',
      status: status,
      priority: conversation.metadata&.dig('priority') || 'normal',
      category: conversation.metadata&.dig('category') || 'general',
      created_at: conversation.created_at,
      updated_at: conversation.updated_at,
      last_activity_at: conversation.updated_at,
      customer: customer ? {
        id: customer.id,
        name: customer.display_name,
        email: customer.email,
        avatar_url: avatar_api_url(customer)
      } : {
        id: nil,
        name: 'Unknown Customer',
        email: 'unknown@example.com',
        avatar_url: nil
      },
      assigned_agent: assigned_agent ? {
        id: assigned_agent.id,
        name: assigned_agent.display_name,
        email: assigned_agent.email
      } : nil,
      last_message: last_msg ? {
        content: last_msg.content,
        created_at: last_msg.created_at,
        from_support: last_msg.user&.has_role?(:support) || false
      } : nil,
      unread_count: calculate_unread_count(conversation, current_user),
      message_count: conversation.messages.where.not(is_system: true).count,
      escalated: conversation.metadata&.dig('escalated') || false,
      package_id: conversation.metadata&.dig('package_id'),
      metadata: conversation.metadata || {}
    }
  end

  def format_agent_info(agent)
    {
      id: agent.id,
      name: agent.display_name,
      email: agent.email,
      online: agent.online?,
      avatar_url: avatar_api_url(agent),
      role: agent.roles.first&.name || 'user',
      last_seen_at: agent.last_seen_at
    }
  end

  def format_message(message)
    {
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      is_system: message.is_system?,
      created_at: message.created_at,
      user: {
        id: message.user.id,
        name: message.user.display_name
      },
      metadata: message.metadata || {}
    }
  end

  def perform_bulk_action(action, ticket_ids)
    conversations = Conversation.where(conversation_type: 'support_ticket', id: ticket_ids)
    results = { success: 0, failed: 0, errors: [] }
    
    conversations.each do |conversation|
      begin
        @conversation = conversation
        
        case action
        when 'close'
          update_conversation_status(conversation, 'closed')
          add_bulk_action_message(conversation, 'closed')
          broadcast_ticket_status_update
        when 'assign_to_me'
          assign_ticket_to_agent(conversation, current_user)
          broadcast_agent_assignment(current_user)
        when 'mark_resolved'
          update_conversation_status(conversation, 'resolved')
          add_bulk_action_message(conversation, 'resolved')
          broadcast_ticket_status_update
        when 'set_priority_high'
          update_conversation_priority(conversation, 'high')
          broadcast_ticket_status_update
        else
          raise "Unknown action: #{action}"
        end
        
        results[:success] += 1
      rescue => e
        results[:failed] += 1
        results[:errors] << { ticket_id: conversation.metadata&.dig('ticket_id') || conversation.id, error: e.message }
      end
    end
    
    results
  end

  def update_conversation_status(conversation, status)
    current_metadata = conversation.metadata || {}
    conversation.metadata = current_metadata.merge('status' => status)
    conversation.save!
  end

  def assign_ticket_to_agent(conversation, agent)
    existing_agent = conversation.conversation_participants.find_by(role: 'agent')
    existing_agent&.destroy

    conversation.conversation_participants.create!(
      user: agent,
      role: 'agent',
      joined_at: Time.current
    )

    update_conversation_status(conversation, 'assigned')
  end

  def add_bulk_action_message(conversation, action)
    message = conversation.messages.create!(
      user: current_user,
      content: "Ticket #{action} via bulk action by #{current_user.display_name}",
      message_type: 'system',
      is_system: true,
      metadata: {
        type: 'bulk_action',
        action: action,
        performed_by: current_user.id
      }
    )
    
    @conversation = conversation
    broadcast_system_message(message)
  end

  def update_conversation_priority(conversation, priority)
    current_metadata = conversation.metadata || {}
    conversation.metadata = current_metadata.merge(
      'priority' => priority,
      'priority_updated_by' => current_user.id,
      'priority_updated_at' => Time.current.iso8601
    )
    conversation.save!
  end

  def calculate_avg_response_time
    # Placeholder - implement actual calculation based on your requirements
    "15m"
  end

  def calculate_satisfaction_score
    # Placeholder - implement actual calculation based on your requirements
    4.2
  end

  def determine_last_action(ticket)
    last_message = ticket.messages.order(created_at: :desc).first
    return 'No activity' unless last_message
    
    if last_message.is_system?
      case last_message.metadata&.dig('type')
      when 'ticket_assigned' then 'Assigned'
      when 'ticket_escalated' then 'Escalated'
      when 'priority_updated' then 'Priority updated'
      else 'System update'
      end
    else
      last_message.user&.has_role?(:support) ? 'Agent replied' : 'Customer replied'
    end
  end

  def calculate_agent_avg_resolution_time(agent)
    # Placeholder - implement actual calculation based on your requirements
    "1h 30m"
  end

  def calculate_agent_satisfaction(agent)
    # Placeholder - implement actual calculation based on your requirements
    4.3
  end

  def calculate_detailed_stats(time_range)
    # Placeholder - implement actual calculation based on your requirements
    {
      time_range: time_range,
      tickets_created: 45,
      tickets_resolved: 38,
      avg_resolution_time: "2h 15m",
      satisfaction_score: 4.1,
      first_response_time: "12m"
    }
  end
end