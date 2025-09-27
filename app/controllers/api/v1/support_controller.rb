# app/controllers/api/v1/support_controller.rb
class Api::V1::SupportController < ApplicationController
  include AvatarHelper  # FIXED: Include avatar helper for R2 support
  
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
      render json: {
        success: false,
        message: 'Failed to load dashboard data'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/support/tickets
  def tickets
    begin
      # Build base query for support tickets
      tickets_query = build_tickets_query
      
      # Apply filters
      tickets_query = apply_ticket_filters(tickets_query)
      
      # Apply pagination
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
      render json: {
        success: false,
        message: 'Failed to load support tickets'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/support/my_tickets
  def my_tickets
    begin
      my_tickets = current_user.conversations
                              .support_tickets
                              .joins(:conversation_participants)
                              .where(conversation_participants: { role: 'agent', user: current_user })
                              .includes(:users, :messages)
                              .recent
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
      
      # Remove existing agent if any
      existing_agent = @conversation.conversation_participants.find_by(role: 'agent')
      existing_agent&.destroy

      # Add new agent
      @conversation.conversation_participants.create!(
        user: agent,
        role: 'agent',
        joined_at: Time.current
      )

      # Update ticket status
      @conversation.update_support_status('assigned')

      # Add system message
      @conversation.messages.create!(
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
      escalate_to = params[:escalate_to] # 'manager', 'technical', 'billing'
      
      # Update ticket priority and metadata
      current_metadata = @conversation.metadata || {}
      @conversation.metadata = current_metadata.merge({
        'priority' => 'high',
        'escalated' => true,
        'escalation_reason' => escalation_reason,
        'escalated_to' => escalate_to,
        'escalated_by' => current_user.id,
        'escalated_at' => Time.current.iso8601
      })
      @conversation.save!

      # Add system message
      @conversation.messages.create!(
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

      # Notify relevant team (implement notification logic as needed)
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
      note_type = params[:note_type] || 'internal' # 'internal', 'customer_visible'
      
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

      render json: {
        success: true,
        message: 'Note added successfully',
        data: {
          note: format_message(note)
        }
      }
    rescue => e
      Rails.logger.error "Error adding note: #{e.message}"
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
      @conversation.metadata = current_metadata.merge({
        'priority' => new_priority,
        'priority_updated_by' => current_user.id,
        'priority_updated_at' => Time.current.iso8601
      })
      @conversation.save!

      # Add system message
      @conversation.messages.create!(
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

      render json: {
        success: true,
        message: 'Priority updated successfully',
        data: {
          ticket: format_support_ticket(@conversation)
        }
      }
    rescue => e
      Rails.logger.error "Error updating priority: #{e.message}"
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
        format_agent_info(agent).merge({
          current_workload: agent.conversations
                                 .support_tickets
                                 .where("metadata->>'status' IN (?)", ['assigned', 'in_progress'])
                                 .count,
          performance_stats: get_agent_performance_stats(agent)
        })
      end

      render json: {
        success: true,
        data: {
          agents: agents_data
        }
      }
    rescue => e
      Rails.logger.error "Error loading agents: #{e.message}"
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
      
      render json: {
        success: true,
        message: "Bulk action '#{action}' completed",
        data: results
      }
    rescue => e
      Rails.logger.error "Error performing bulk action: #{e.message}"
      render json: {
        success: false,
        message: 'Failed to perform bulk action'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/support/stats
  def stats
    begin
      time_range = params[:time_range] || '7d' # '1d', '7d', '30d', '90d'
      
      stats = calculate_detailed_stats(time_range)
      
      render json: {
        success: true,
        data: stats
      }
    rescue => e
      Rails.logger.error "Error loading stats: #{e.message}"
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
      current_user.accessible_conversations.support_tickets
    end
  end

  def build_tickets_query
    query = accessible_conversations.includes(:conversation_participants, :users, :messages)
    
    # Default ordering
    query.recent
  end

  def apply_ticket_filters(query)
    # Status filter
    if params[:status].present?
      query = query.where("metadata->>'status' = ?", params[:status])
    end

    # Priority filter
    if params[:priority].present?
      query = query.where("metadata->>'priority' = ?", params[:priority])
    end

    # Category filter
    if params[:category].present?
      query = query.where("metadata->>'category' = ?", params[:category])
    end

    # Agent filter
    if params[:agent_id].present?
      query = query.joins(:conversation_participants)
                  .where(conversation_participants: { user_id: params[:agent_id], role: 'agent' })
    end

    # Unassigned filter
    if params[:unassigned] == 'true'
      query = query.left_joins(:conversation_participants)
                  .where(conversation_participants: { role: 'agent' })
                  .where(conversation_participants: { id: nil })
    end

    # Date range filter
    if params[:created_after].present?
      query = query.where('created_at >= ?', params[:created_after])
    end

    if params[:created_before].present?
      query = query.where('created_at <= ?', params[:created_before])
    end

    # Search filter
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
    {
      status: params[:status],
      priority: params[:priority],
      category: params[:category],
      agent_id: params[:agent_id],
      unassigned: params[:unassigned],
      search: params[:search],
      date_range: {
        after: params[:created_after],
        before: params[:created_before]
      }
    }.compact
  end

  def calculate_dashboard_stats
    base_tickets = accessible_conversations

    {
      total_tickets: base_tickets.count,
      pending_tickets: base_tickets.where("metadata->>'status' = 'pending'").count,
      in_progress_tickets: base_tickets.where("metadata->>'status' = 'in_progress'").count,
      resolved_today: base_tickets.where("metadata->>'status' = 'resolved'")
                                 .where(updated_at: Date.current.all_day).count,
      avg_response_time: calculate_avg_response_time,
      satisfaction_score: calculate_satisfaction_score,
      tickets_by_priority: {
        high: base_tickets.where("metadata->>'priority' = 'high'").count,
        normal: base_tickets.where("metadata->>'priority' = 'normal'").count,
        low: base_tickets.where("metadata->>'priority' = 'low'").count
      },
      tickets_by_category: calculate_tickets_by_category,
      trends: calculate_ticket_trends
    }
  end

  def get_recent_activity
    recent_tickets = accessible_conversations
                    .includes(:users, :messages)
                    .where(updated_at: 24.hours.ago..Time.current)
                    .order(updated_at: :desc)
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
    
    {
      tickets_resolved_today: target_agent.conversations
                                         .support_tickets
                                         .where("metadata->>'status' = 'resolved'")
                                         .where(updated_at: Date.current.all_day)
                                         .count,
      avg_resolution_time: calculate_agent_avg_resolution_time(target_agent),
      active_tickets: target_agent.conversations
                                 .support_tickets
                                 .where("metadata->>'status' IN (?)", ['assigned', 'in_progress'])
                                 .count,
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
        avatar_url: avatar_api_url(conversation.customer)  # FIXED: Use avatar helper instead of direct Active Storage
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
      avatar_url: avatar_api_url(agent),  # FIXED: Use avatar helper instead of direct Active Storage
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
        case action
        when 'close'
          conversation.update_support_status('closed')
          add_bulk_action_message(conversation, 'closed')
        when 'assign_to_me'
          assign_ticket_to_agent(conversation, current_user)
        when 'mark_resolved'
          conversation.update_support_status('resolved')
          add_bulk_action_message(conversation, 'resolved')
        when 'set_priority_high'
          update_conversation_priority(conversation, 'high')
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
    # Remove existing agent
    existing_agent = conversation.conversation_participants.find_by(role: 'agent')
    existing_agent&.destroy

    # Add new agent
    conversation.conversation_participants.create!(
      user: agent,
      role: 'agent',
      joined_at: Time.current
    )

    conversation.update_support_status('assigned')
  end

  def add_bulk_action_message(conversation, action)
    conversation.messages.create!(
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
  end

  def update_conversation_priority(conversation, priority)
    current_metadata = conversation.metadata || {}
    conversation.metadata = current_metadata.merge({
      'priority' => priority,
      'priority_updated_by' => current_user.id,
      'priority_updated_at' => Time.current.iso8601
    })
    conversation.save!
  end

  def calculate_avg_response_time
    # Implementation for calculating average response time
    # This would require tracking response timestamps
    "2.5 hours" # Placeholder
  end

  def calculate_satisfaction_score
    # Implementation for calculating satisfaction scores
    # This would require customer feedback/rating system
    4.2 # Placeholder
  end

  def calculate_tickets_by_category
    accessible_conversations.group("metadata->>'category'").count
  end

  def calculate_ticket_trends
    # Calculate trends over time periods
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
    # Implementation for agent-specific resolution time
    "1.8 hours" # Placeholder
  end

  def calculate_agent_satisfaction(agent)
    # Implementation for agent-specific satisfaction
    4.3 # Placeholder
  end

  def calculate_detailed_stats(time_range)
    # Implementation for detailed statistics based on time range
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
    # Implementation for notifying escalation teams
    # This could send emails, create notifications, etc.
    Rails.logger.info "Ticket #{conversation.ticket_id} escalated to #{team} team: #{reason}"
  end
end