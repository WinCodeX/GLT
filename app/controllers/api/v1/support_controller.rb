# app/controllers/api/v1/support_controller.rb
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
        message: 'Failed to load dashboard data'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/support/tickets
  def tickets
    begin
      tickets_query = build_tickets_query
      tickets_query = apply_ticket_filters(tickets_query)
      
      page = [params[:page].to_i, 1].max
      limit = [params[:limit].to_i, 20].max.clamp(1, 100)
      
      tickets = tickets_query.includes(:conversation_participants, :users, :messages)
                            .limit(limit)
                            .offset((page - 1) * limit)
      
      total_count = tickets_query.count
      
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
      Rails.logger.error "Error loading support tickets: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load support tickets'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/support/my_tickets
  def my_tickets
    begin
      my_tickets = Conversation.support_tickets
                              .joins(:conversation_participants)
                              .where(conversation_participants: { role: 'agent', user_id: current_user.id })
                              .includes(:users, :messages)
                              .order(updated_at: :desc)
                              .limit(50)

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
        message: 'Failed to load your tickets'
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

      agent = User.with_role(:support).find(agent_id)
      
      existing_agent = @conversation.conversation_participants.find_by(role: 'agent')
      existing_agent&.destroy

      @conversation.conversation_participants.create!(
        user: agent,
        role: 'agent',
        joined_at: Time.current
      )

      @conversation.update_support_status('assigned')

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
        message: 'Failed to assign ticket'
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

      notify_escalation_team(escalate_to, @conversation, escalation_reason)

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
        message: 'Failed to escalate ticket'
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
        message: 'Failed to add note'
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

      old_priority = @conversation.priority
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

      broadcast_ticket_status_update(@conversation.status)
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
        message: 'Failed to update priority'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/support/agents
  def agents
    begin
      agents = User.with_role(:support)
                  .includes(:conversation_participants)
                  .order(:first_name, :last_name)

      agents_data = agents.map do |agent|
        agent_tickets = Conversation.support_tickets
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
        message: 'Failed to load agents'
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
        message: 'Failed to perform bulk action'
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
        message: 'Failed to load statistics'
      }, status: :internal_server_error
    end
  end

  private

  def set_conversation
    @conversation = accessible_conversations.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: {
      success: false,
      message: 'Ticket not found'
    }, status: :not_found
  end

  def ensure_support_access!
    unless current_user.support_staff?
      render json: {
        success: false,
        message: 'Access denied. Support role required.'
      }, status: :forbidden
    end
  end

  def accessible_conversations
    if current_user.admin?
      Conversation.support_tickets
    else
      Conversation.support_tickets
                  .joins(:conversation_participants)
                  .where(conversation_participants: { role: 'agent', user_id: current_user.id })
                  .distinct
    end
  end

  def build_tickets_query
    accessible_conversations.includes(:conversation_participants, :users, :messages).order(updated_at: :desc)
  end

  def apply_ticket_filters(query)
    query = query.where("conversations.metadata->>'status' = ?", params[:status]) if params[:status].present?
    query = query.where("conversations.metadata->>'priority' = ?", params[:priority]) if params[:priority].present?
    query = query.where("conversations.metadata->>'category' = ?", params[:category]) if params[:category].present?

    if params[:agent_id].present?
      query = query.joins(:conversation_participants)
                  .where(conversation_participants: { user_id: params[:agent_id], role: 'agent' })
    end

    if params[:unassigned] == 'true'
      query = query.left_joins(:conversation_participants)
                  .where("conversation_participants.role = 'agent' AND conversation_participants.id IS NULL")
    end

    query = query.where('conversations.created_at >= ?', params[:created_after]) if params[:created_after].present?
    query = query.where('conversations.created_at <= ?', params[:created_before]) if params[:created_before].present?

    if params[:search].present?
      search_term = "%#{params[:search]}%"
      query = query.joins(:users)
                  .where(
                    "conversations.title ILIKE ? OR users.first_name ILIKE ? OR users.last_name ILIKE ? OR conversations.metadata->>'ticket_id' ILIKE ?",
                    search_term, search_term, search_term, search_term
                  )
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

  def broadcast_ticket_status_update(new_status)
    ActionCable.server.broadcast(
      "support_dashboard",
      {
        type: 'ticket_status_update',
        ticket_id: @conversation.id,
        status: new_status,
        timestamp: Time.current.iso8601
      }
    )

    ActionCable.server.broadcast(
      "conversation_#{@conversation.id}",
      {
        type: 'ticket_status_changed',
        conversation_id: @conversation.id,
        new_status: new_status,
        timestamp: Time.current.iso8601
      }
    )
    
    Rails.logger.info "✅ Status update broadcast to dashboard: #{new_status}"
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
        role: message.user.primary_role
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
    base_tickets = accessible_conversations

    {
      total_tickets: base_tickets.count,
      pending_tickets: base_tickets.where("conversations.metadata->>'status' = ?", 'pending').count,
      in_progress_tickets: base_tickets.where("conversations.metadata->>'status' = ?", 'in_progress').count,
      resolved_today: base_tickets.where("conversations.metadata->>'status' = ?", 'resolved')
                                 .where('conversations.updated_at >= ?', Time.current.beginning_of_day).count,
      avg_response_time: calculate_avg_response_time,
      satisfaction_score: calculate_satisfaction_score,
      tickets_by_priority: {
        high: base_tickets.where("conversations.metadata->>'priority' = ?", 'high').count,
        normal: base_tickets.where("conversations.metadata->>'priority' = ?", 'normal').count,
        low: base_tickets.where("conversations.metadata->>'priority' = ?", 'low').count
      },
      tickets_by_category: calculate_tickets_by_category,
      trends: calculate_ticket_trends
    }
  end

  def get_recent_activity
    recent_tickets = accessible_conversations
                    .includes(:users, :messages)
                    .where('conversations.updated_at >= ?', 24.hours.ago)
                    .order('conversations.updated_at DESC')
                    .limit(10)

    recent_tickets.map do |ticket|
      {
        ticket_id: ticket.ticket_id,
        customer_name: ticket.customer&.display_name,
        action: determine_last_action(ticket),
        timestamp: ticket.updated_at,
        agent: ticket.assigned_agent&.display_name
      }
    end
  end

  def get_agent_performance_stats(agent = nil)
    target_agent = agent || current_user
    
    agent_tickets = Conversation.support_tickets
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
    {
      id: conversation.id,
      ticket_id: conversation.ticket_id,
      title: conversation.title,
      status: conversation.status,
      priority: conversation.priority || 'normal',
      category: conversation.category || 'general',
      created_at: conversation.created_at,
      updated_at: conversation.updated_at,
      last_activity_at: conversation.last_activity_at,
      customer: conversation.customer ? {
        id: conversation.customer.id,
        name: conversation.customer.display_name,
        email: conversation.customer.email,
        avatar_url: avatar_api_url(conversation.customer)
      } : nil,
      assigned_agent: conversation.assigned_agent ? {
        id: conversation.assigned_agent.id,
        name: conversation.assigned_agent.display_name,
        email: conversation.assigned_agent.email
      } : nil,
      last_message: conversation.last_message ? {
        content: conversation.last_message.content,
        created_at: conversation.last_message.created_at,
        from_support: conversation.last_message.from_support?
      } : nil,
      unread_count: conversation.unread_count_for(current_user),
      message_count: conversation.messages.count,
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
      role: agent.primary_role,
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
    conversations = accessible_conversations.where(id: ticket_ids)
    results = { success: 0, failed: 0, errors: [] }
    
    conversations.each do |conversation|
      begin
        @conversation = conversation
        
        case action
        when 'close'
          conversation.update_support_status('closed')
          add_bulk_action_message(conversation, 'closed')
          broadcast_ticket_status_update('closed')
        when 'assign_to_me'
          assign_ticket_to_agent(conversation, current_user)
          broadcast_agent_assignment(current_user)
        when 'mark_resolved'
          conversation.update_support_status('resolved')
          add_bulk_action_message(conversation, 'resolved')
          broadcast_ticket_status_update('resolved')
        when 'set_priority_high'
          update_conversation_priority(conversation, 'high')
          broadcast_ticket_status_update(conversation.status)
        else
          raise "Unknown action: #{action}"
        end
        
        results[:success] += 1
      rescue => e
        results[:failed] += 1
        results[:errors] << { ticket_id: conversation.ticket_id, error: e.message }
      end
    end
    
    results
  end

  def assign_ticket_to_agent(conversation, agent)
    existing_agent = conversation.conversation_participants.find_by(role: 'agent')
    existing_agent&.destroy

    conversation.conversation_participants.create!(
      user: agent,
      role: 'agent',
      joined_at: Time.current
    )

    conversation.update_support_status('assigned')
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
    "2.5 hours"
  end

  def calculate_satisfaction_score
    4.2
  end

  def calculate_tickets_by_category
    accessible_conversations.group("conversations.metadata->>'category'").count
  end

  def calculate_ticket_trends
    {
      daily_trend: "↑12%",
      weekly_trend: "↓3%",
      resolution_trend: "↑8%"
    }
  end

  def determine_last_action(ticket)
    last_message = ticket.messages.order(:created_at).last
    return 'No activity' unless last_message
    
    if last_message.is_system?
      case last_message.metadata&.dig('type')
      when 'ticket_assigned' then 'Assigned'
      when 'ticket_escalated' then 'Escalated'
      when 'priority_updated' then 'Priority updated'
      else 'System update'
      end
    else
      last_message.from_support? ? 'Agent replied' : 'Customer replied'
    end
  end

  def calculate_agent_avg_resolution_time(agent)
    "1.8 hours"
  end

  def calculate_agent_satisfaction(agent)
    4.3
  end

  def calculate_detailed_stats(time_range)
    {
      time_range: time_range,
      tickets_created: 45,
      tickets_resolved: 38,
      avg_resolution_time: "2.1 hours",
      satisfaction_score: 4.1,
      first_response_time: "12 minutes"
    }
  end

  def notify_escalation_team(team, conversation, reason)
    Rails.logger.info "Ticket #{conversation.ticket_id} escalated to #{team} team: #{reason}"
  end
end