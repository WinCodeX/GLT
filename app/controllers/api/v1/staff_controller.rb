# app/controllers/api/v1/staff_controller.rb
class Api::V1::StaffController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_staff_access!
  before_action :set_package, only: [:show_package, :track_package, :reject_package]

  # GET /api/v1/staff/dashboard/stats
  def dashboard_stats
    begin
      stats = calculate_staff_dashboard_stats
      
      render json: {
        success: true,
        data: stats
      }
    rescue => e
      Rails.logger.error "Error loading staff dashboard stats: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load dashboard statistics'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/staff/packages
  def packages
    begin
      packages_query = build_staff_packages_query
      packages_query = apply_package_filters(packages_query)
      
      page = [params[:page].to_i, 1].max
      limit = [params[:limit].to_i, 20].max.clamp(1, 100)
      
      packages = packages_query.includes(:user, :origin_area, :destination_area, :origin_agent, :destination_agent)
                               .limit(limit)
                               .offset((page - 1) * limit)
      
      total_count = packages_query.count
      
      render json: {
        success: true,
        data: {
          packages: packages.map { |pkg| format_package_for_staff(pkg) },
          pagination: {
            current_page: page,
            total_pages: (total_count.to_f / limit).ceil,
            total_count: total_count,
            per_page: limit
          }
        }
      }
    rescue => e
      Rails.logger.error "Error loading staff packages: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load packages'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/staff/packages/:id
  def show_package
    begin
      render json: {
        success: true,
        data: {
          package: format_package_details(@package)
        }
      }
    rescue => e
      Rails.logger.error "Error loading package details: #{e.message}"
      render json: {
        success: false,
        message: 'Failed to load package details'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/staff/packages/:id/track
  def track_package
    begin
      tracking_info = {
        package: format_package_for_staff(@package),
        tracking_events: @package.tracking_events.includes(:user).order(created_at: :desc).map { |event| format_tracking_event(event) },
        print_logs: @package.print_logs.includes(:user).order(printed_at: :desc).map { |log| format_print_log(log) },
        current_status: @package.state,
        status_history: generate_status_history(@package),
        estimated_delivery: calculate_estimated_delivery(@package),
        route_info: {
          origin: @package.location_based_delivery? ? @package.pickup_location : @package.origin_area&.full_name,
          destination: @package.location_based_delivery? ? @package.delivery_location : @package.destination_area&.full_name,
          route_description: @package.route_description
        }
      }
      
      render json: {
        success: true,
        data: tracking_info
      }
    rescue => e
      Rails.logger.error "Error tracking package: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load tracking information'
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/staff/packages/:id/reject
  def reject_package
    begin
      rejection_reason = params[:reason]
      rejection_type = params[:rejection_type]
      
      if rejection_reason.blank?
        return render json: {
          success: false,
          message: 'Rejection reason is required'
        }, status: :unprocessable_entity
      end

      # Check if package is in rejectable state
      unless ['pending', 'submitted'].include?(@package.state)
        return render json: {
          success: false,
          message: "Package cannot be rejected in #{@package.state} state"
        }, status: :unprocessable_entity
      end

      if @package.reject_package!(reason: rejection_reason, auto_rejected: false)
        # Create rejection tracking event
        PackageTrackingEvent.create!(
          package: @package,
          user: current_user,
          event_type: 'rejected',
          metadata: {
            rejection_reason: rejection_reason,
            rejection_type: rejection_type,
            rejected_by_role: current_user.primary_role,
            staff_id: current_user.id,
            staff_name: current_user.display_name
          }
        )

        # Broadcast rejection to user
        broadcast_package_rejection(@package, rejection_reason)
        
        # Broadcast stats update
        broadcast_staff_dashboard_update

        render json: {
          success: true,
          message: 'Package rejected successfully',
          data: {
            package: format_package_for_staff(@package),
            rejection_info: {
              reason: rejection_reason,
              type: rejection_type,
              rejected_by: current_user.display_name,
              rejected_at: Time.current
            }
          }
        }
      else
        render json: {
          success: false,
          message: 'Failed to reject package'
        }, status: :unprocessable_entity
      end
    rescue => e
      Rails.logger.error "Error rejecting package: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to reject package'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/staff/scan_events
  def scan_events
    begin
      page = [params[:page].to_i, 1].max
      limit = [params[:limit].to_i, 20].max.clamp(1, 50)
      
      events_query = current_user.package_tracking_events
                                 .includes(:package, :user)
                                 .order(created_at: :desc)
      
      # Apply filters
      events_query = events_query.where(event_type: params[:event_type]) if params[:event_type].present?
      events_query = events_query.where('created_at >= ?', params[:start_date]) if params[:start_date].present?
      events_query = events_query.where('created_at <= ?', params[:end_date]) if params[:end_date].present?
      
      if params[:package_id].present?
        package = Package.find_by(id: params[:package_id]) || Package.find_by(code: params[:package_id])
        events_query = events_query.where(package: package) if package
      end
      
      events = events_query.limit(limit).offset((page - 1) * limit)
      total_count = events_query.count
      
      render json: {
        success: true,
        data: {
          scan_events: events.map { |event| format_tracking_event(event) },
          pagination: {
            current_page: page,
            total_pages: (total_count.to_f / limit).ceil,
            total_count: total_count,
            per_page: limit
          },
          summary: {
            total_scans: current_user.package_tracking_events.count,
            scans_today: current_user.package_tracking_events.where(created_at: Date.current.all_day).count,
            scans_this_week: current_user.package_tracking_events.where(created_at: 1.week.ago..Time.current).count,
            packages_scanned: current_user.package_tracking_events.select(:package_id).distinct.count
          }
        }
      }
    rescue => e
      Rails.logger.error "Error loading scan events: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load scan events'
      }, status: :internal_server_error
    end
  end

  # POST /api/v1/staff/scan_events
  def create_scan_event
    begin
      package_code = params[:package_code]
      event_type = params[:event_type]
      location = params[:location]
      metadata = params[:metadata] || {}
      
      if package_code.blank?
        return render json: {
          success: false,
          message: 'Package code is required'
        }, status: :unprocessable_entity
      end

      package = Package.find_by(code: package_code)
      
      unless package
        return render json: {
          success: false,
          message: 'Package not found'
        }, status: :not_found
      end

      # Determine event type based on user role if not provided
      event_type ||= determine_event_type_for_role(current_user.primary_role)
      
      # Validate event type for user role
      unless valid_event_type_for_role?(event_type, current_user.primary_role)
        return render json: {
          success: false,
          message: 'Invalid event type for your role'
        }, status: :unprocessable_entity
      end

      tracking_event = PackageTrackingEvent.create!(
        package: package,
        user: current_user,
        event_type: event_type,
        metadata: metadata.merge({
          location: location,
          scanned_by_role: current_user.primary_role,
          staff_name: current_user.display_name,
          timestamp: Time.current.iso8601
        })
      )

      # Broadcast the scan event
      broadcast_scan_event(package, tracking_event)
      broadcast_staff_dashboard_update

      render json: {
        success: true,
        message: 'Scan event created successfully',
        data: {
          scan_event: format_tracking_event(tracking_event),
          package: format_package_for_staff(package)
        }
      }
    rescue ActiveRecord::RecordInvalid => e
      render json: {
        success: false,
        message: e.message
      }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error "Error creating scan event: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to create scan event'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/staff/activities
  def activities
    begin
      page = [params[:page].to_i, 1].max
      limit = [params[:limit].to_i, 20].max.clamp(1, 50)
      
      # Combine tracking events and print logs for comprehensive activity history
      tracking_events = current_user.package_tracking_events
                                    .includes(:package)
                                    .order(created_at: :desc)
      
      print_logs = current_user.package_print_logs
                               .includes(:package)
                               .order(printed_at: :desc)
      
      # Apply date filters
      if params[:start_date].present?
        tracking_events = tracking_events.where('created_at >= ?', params[:start_date])
        print_logs = print_logs.where('printed_at >= ?', params[:start_date])
      end
      
      if params[:end_date].present?
        tracking_events = tracking_events.where('created_at <= ?', params[:end_date])
        print_logs = print_logs.where('printed_at <= ?', params[:end_date])
      end
      
      # Apply activity type filter
      if params[:activity_type].present?
        case params[:activity_type]
        when 'scan'
          print_logs = PackagePrintLog.none
        when 'print'
          tracking_events = PackageTrackingEvent.none
        end
      end
      
      # Combine and sort activities
      all_activities = []
      
      tracking_events.limit(limit).each do |event|
        all_activities << {
          id: "event_#{event.id}",
          type: 'scan',
          activity_type: event.event_type,
          description: event.event_description,
          package_code: event.package.code,
          package_id: event.package.id,
          timestamp: event.created_at,
          metadata: event.metadata,
          category: event.event_category
        }
      end
      
      print_logs.limit(limit).each do |log|
        all_activities << {
          id: "print_#{log.id}",
          type: 'print',
          activity_type: log.print_context,
          description: log.print_context_display,
          package_code: log.package.code,
          package_id: log.package.id,
          timestamp: log.printed_at,
          metadata: log.metadata,
          copies: log.copies_printed,
          status: log.status
        }
      end
      
      # Sort by timestamp
      all_activities.sort_by! { |a| a[:timestamp] }.reverse!
      
      # Paginate
      paginated_activities = all_activities[((page - 1) * limit)...(page * limit)] || []
      
      render json: {
        success: true,
        data: {
          activities: paginated_activities,
          pagination: {
            current_page: page,
            total_pages: (all_activities.length.to_f / limit).ceil,
            total_count: all_activities.length,
            per_page: limit
          },
          summary: {
            total_activities: all_activities.length,
            scans: tracking_events.count,
            prints: print_logs.count,
            packages_handled: (tracking_events.select(:package_id).distinct.pluck(:package_id) + 
                              print_logs.select(:package_id).distinct.pluck(:package_id)).uniq.length
          }
        }
      }
    rescue => e
      Rails.logger.error "Error loading activities: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load activities'
      }, status: :internal_server_error
    end
  end

  # GET /api/v1/staff/rejections
  def rejections
    begin
      page = [params[:page].to_i, 1].max
      limit = [params[:limit].to_i, 20].max.clamp(1, 50)
      
      # Find all rejection events by this staff member
      rejection_events = PackageTrackingEvent.where(
        user: current_user,
        event_type: 'rejected'
      ).includes(:package).order(created_at: :desc)
      
      # Apply date filters
      rejection_events = rejection_events.where('created_at >= ?', params[:start_date]) if params[:start_date].present?
      rejection_events = rejection_events.where('created_at <= ?', params[:end_date]) if params[:end_date].present?
      
      events = rejection_events.limit(limit).offset((page - 1) * limit)
      total_count = rejection_events.count
      
      rejections = events.map do |event|
        {
          id: event.id,
          package_code: event.package.code,
          package_id: event.package.id,
          rejection_reason: event.metadata['rejection_reason'],
          rejection_type: event.metadata['rejection_type'],
          rejected_at: event.created_at,
          package_state: event.package.state,
          sender_name: event.package.user.display_name,
          route_description: event.package.route_description
        }
      end
      
      render json: {
        success: true,
        data: {
          rejections: rejections,
          pagination: {
            current_page: page,
            total_pages: (total_count.to_f / limit).ceil,
            total_count: total_count,
            per_page: limit
          },
          summary: {
            total_rejections: total_count,
            rejections_today: rejection_events.where(created_at: Date.current.all_day).count,
            rejections_this_week: rejection_events.where(created_at: 1.week.ago..Time.current).count,
            rejection_types: rejection_events.group("metadata->>'rejection_type'").count
          }
        }
      }
    rescue => e
      Rails.logger.error "Error loading rejections: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: 'Failed to load rejections'
      }, status: :internal_server_error
    end
  end

  private

  def ensure_staff_access!
    unless current_user.staff?
      render json: {
        success: false,
        message: 'Access denied. Staff role required.'
      }, status: :forbidden
    end
  end

  def set_package
    @package = Package.find_by(id: params[:id]) || Package.find_by(code: params[:id])
    
    unless @package
      render json: {
        success: false,
        message: 'Package not found'
      }, status: :not_found
    end
  end

  def build_staff_packages_query
    # All staff can see all packages
    Package.all
  end

  def apply_package_filters(query)
    query = query.where(state: params[:state]) if params[:state].present?
    query = query.where(delivery_type: params[:delivery_type]) if params[:delivery_type].present?
    
    if params[:origin_area_id].present?
      query = query.where(origin_area_id: params[:origin_area_id])
    end
    
    if params[:destination_area_id].present?
      query = query.where(destination_area_id: params[:destination_area_id])
    end
    
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      query = query.where(
        "code ILIKE ? OR receiver_name ILIKE ? OR receiver_phone ILIKE ?",
        search_term, search_term, search_term
      )
    end
    
    query = query.where('created_at >= ?', params[:created_after]) if params[:created_after].present?
    query = query.where('created_at <= ?', params[:created_before]) if params[:created_before].present?
    
    query.order(created_at: :desc)
  end

  def calculate_staff_dashboard_stats
    base_packages = Package.all
    
    # Calculate today's date range
    today_start = Date.current.beginning_of_day
    today_end = Date.current.end_of_day
    
    # Active deliveries (in_transit state)
    active_deliveries = base_packages.where(state: 'in_transit').count
    
    # Completed today (delivered or collected today)
    completed_today = base_packages.where(state: ['delivered', 'collected'])
                                  .where(updated_at: today_start..today_end)
                                  .count
    
    # Revenue today (sum of package costs for completed packages today)
    revenue_today = base_packages.where(state: ['delivered', 'collected'])
                                .where(updated_at: today_start..today_end)
                                .sum(:cost)
    
    # Pending packages count
    pending_packages_count = base_packages.where(state: ['pending', 'pending_unpaid', 'submitted']).count
    
    # Pending packages grouped by sender location/agent
    pending_packages_grouped = base_packages.where(state: ['pending', 'pending_unpaid', 'submitted'])
                                           .includes(:origin_area, :origin_agent)
                                           .group_by do |pkg|
      if pkg.origin_agent
        {
          type: 'agent',
          id: pkg.origin_agent.id,
          name: pkg.origin_agent.name,
          location: pkg.origin_area&.full_name || 'Unknown'
        }
      elsif pkg.origin_area
        {
          type: 'area',
          id: pkg.origin_area.id,
          name: pkg.origin_area.name,
          location: pkg.origin_area.full_name
        }
      else
        {
          type: 'unknown',
          id: nil,
          name: 'Unknown Location',
          location: 'Unknown'
        }
      end
    end
    
    pending_by_location = pending_packages_grouped.map do |location_info, packages|
      {
        office_name: location_info[:name],
        location: location_info[:location],
        type: location_info[:type],
        count: packages.count,
        packages: packages.map { |pkg| format_package_summary(pkg) }
      }
    end.sort_by { |loc| -loc[:count] }
    
    {
      active_deliveries: active_deliveries,
      completed_today: completed_today,
      revenue_today: revenue_today,
      pending_packages: {
        total: pending_packages_count,
        by_location: pending_by_location
      },
      staff_info: {
        id: current_user.id,
        name: current_user.display_name,
        role: current_user.primary_role,
        role_display: current_user.role_display_name
      },
      activity_summary: {
        scans_today: current_user.package_tracking_events.where(created_at: today_start..today_end).count,
        prints_today: current_user.package_print_logs.where(printed_at: today_start..today_end).count,
        packages_handled_today: current_user.package_tracking_events
                                           .where(created_at: today_start..today_end)
                                           .select(:package_id).distinct.count
      }
    }
  end

  def format_package_for_staff(package)
    {
      id: package.id,
      code: package.code,
      state: package.state,
      state_display: package.state.humanize,
      delivery_type: package.delivery_type,
      delivery_type_display: package.delivery_type_display,
      package_size: package.package_size,
      cost: package.cost,
      created_at: package.created_at,
      updated_at: package.updated_at,
      sender: {
        name: package.user.display_name,
        phone: package.user.phone_number
      },
      receiver: {
        name: package.receiver_name,
        phone: package.receiver_phone
      },
      route: {
        origin: package.location_based_delivery? ? package.pickup_location : package.origin_area&.full_name,
        destination: package.location_based_delivery? ? package.delivery_location : package.destination_area&.full_name,
        description: package.route_description
      },
      requires_special_handling: package.requires_special_handling?,
      priority_level: package.priority_level,
      can_be_rejected: ['pending', 'submitted'].include?(package.state)
    }
  end

  def format_package_summary(package)
    {
      id: package.id,
      code: package.code,
      state: package.state,
      receiver_name: package.receiver_name,
      destination: package.location_based_delivery? ? package.delivery_location : package.destination_area&.name
    }
  end

  def format_package_details(package)
    format_package_for_staff(package).merge(
      tracking_summary: {
        total_events: package.tracking_events.count,
        last_scan: package.tracking_events.order(created_at: :desc).first&.created_at,
        print_count: package.print_logs.count
      },
      payment_info: package.requires_collection? ? {
        payment_type: package.payment_type,
        payment_status: package.payment_status,
        collection_amount: package.collection_amount,
        requires_collection: true
      } : nil,
      special_instructions: package.special_instructions,
      handling_instructions: package.handling_instructions,
      metadata: package.metadata
    )
  end

  def format_tracking_event(event)
    {
      id: event.id,
      event_type: event.event_type,
      event_type_display: event.event_type.humanize,
      description: event.event_description,
      category: event.event_category,
      created_at: event.created_at,
      timestamp: event.created_at.strftime('%Y-%m-%d %H:%M:%S'),
      user: {
        id: event.user.id,
        name: event.user.display_name,
        role: event.user.primary_role
      },
      package: {
        id: event.package.id,
        code: event.package.code
      },
      metadata: event.metadata,
      location: event.location_info
    }
  end

  def format_print_log(log)
    {
      id: log.id,
      print_context: log.print_context,
      print_context_display: log.print_context_display,
      status: log.status,
      status_display: log.status_display,
      printed_at: log.printed_at,
      copies_printed: log.copies_printed,
      user: {
        id: log.user.id,
        name: log.user.display_name,
        role: log.user.primary_role
      },
      package: {
        id: log.package.id,
        code: log.package.code
      },
      metadata: log.metadata
    }
  end

  def generate_status_history(package)
    package.tracking_events.where.not(event_type: ['scan_error', 'processing_error'])
           .order(created_at: :asc)
           .map do |event|
      {
        status: event.event_type,
        timestamp: event.created_at,
        description: event.event_description,
        user: event.user.display_name
      }
    end
  end

  def calculate_estimated_delivery(package)
    return nil if package.delivered? || package.collected?
    
    case package.state
    when 'pending_unpaid', 'pending'
      'Awaiting payment/submission'
    when 'submitted'
      (package.created_at + 2.days).strftime('%Y-%m-%d')
    when 'in_transit'
      (Time.current + 1.day).strftime('%Y-%m-%d')
    else
      'Unknown'
    end
  end

  def determine_event_type_for_role(role)
    case role
    when 'agent'
      'printed_by_agent'
    when 'rider'
      'collected_by_rider'
    when 'warehouse'
      'processed_by_warehouse'
    else
      'state_changed'
    end
  end

  def valid_event_type_for_role?(event_type, role)
    valid_events = PackageTrackingEvent.role_event_types(role)
    valid_events.include?(event_type)
  end

  def broadcast_package_rejection(package, reason)
    ActionCable.server.broadcast(
      "user_packages_#{package.user_id}",
      {
        type: 'package_rejected',
        package_id: package.id,
        package_code: package.code,
        reason: reason,
        rejected_by: current_user.display_name,
        rejected_by_role: current_user.role_display_name,
        timestamp: Time.current.iso8601
      }
    )
    
    Rails.logger.info "✅ Package rejection broadcast to user #{package.user_id}"
  end

  def broadcast_scan_event(package, event)
    ActionCable.server.broadcast(
      "user_packages_#{package.user_id}",
      {
        type: 'package_scanned',
        package_id: package.id,
        package_code: package.code,
        event_type: event.event_type,
        scanned_by: current_user.display_name,
        location: event.metadata['location'],
        timestamp: Time.current.iso8601
      }
    )
    
    Rails.logger.info "✅ Scan event broadcast to user #{package.user_id}"
  end

  def broadcast_staff_dashboard_update
    # Broadcast to all staff members
    ActionCable.server.broadcast(
      "staff_dashboard",
      {
        type: 'dashboard_stats_update',
        stats: calculate_staff_dashboard_stats,
        timestamp: Time.current.iso8601
      }
    )
    
    Rails.logger.info "✅ Staff dashboard stats broadcast"
  end
end