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
      tracking_events = @package.tracking_events.includes(:user).order(created_at: :desc) rescue []
      print_logs = @package.print_logs.includes(:user).order(printed_at: :desc) rescue []
      
      tracking_info = {
        package: format_package_for_staff(@package),
        tracking_events: tracking_events.map { |event| format_tracking_event(event) },
        print_logs: print_logs.map { |log| format_print_log(log) },
        current_status: @package.state,
        status_history: generate_status_history(@package),
        estimated_delivery: calculate_estimated_delivery(@package),
        route_info: {
          origin: @package.location_based_delivery? ? @package.pickup_location : @package.origin_area&.full_name,
          destination: @package.location_based_delivery? ? @package.delivery_location : @package.destination_area&.full_name,
          route_description: get_package_route_description(@package)
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

      unless ['pending', 'submitted'].include?(@package.state)
        return render json: {
          success: false,
          message: "Package cannot be rejected in #{@package.state} state"
        }, status: :unprocessable_entity
      end

      if @package.reject_package!(reason: rejection_reason, auto_rejected: false)
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

        broadcast_package_rejection(@package, rejection_reason)
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
      
      events_query = PackageTrackingEvent.where(user: current_user)
                                         .includes(:package, :user)
                                         .order(created_at: :desc)
      
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
            total_scans: PackageTrackingEvent.where(user: current_user).count,
            scans_today: PackageTrackingEvent.where(user: current_user, created_at: Date.current.all_day).count,
            scans_this_week: PackageTrackingEvent.where(user: current_user, created_at: 1.week.ago..Time.current).count,
            packages_scanned: PackageTrackingEvent.where(user: current_user).select(:package_id).distinct.count
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

      event_type ||= determine_event_type_for_role(current_user.primary_role)
      
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
      
      # Fetch tracking events
      tracking_events_query = PackageTrackingEvent.where(user: current_user)
                                                   .includes(:package)
                                                   .order(created_at: :desc)
      
      # Fetch print logs
      print_logs_query = PackagePrintLog.where(user: current_user)
                                        .includes(:package)
                                        .order(printed_at: :desc)
      
      # Apply date filters
      if params[:start_date].present?
        tracking_events_query = tracking_events_query.where('created_at >= ?', params[:start_date])
        print_logs_query = print_logs_query.where('printed_at >= ?', params[:start_date])
      end
      
      if params[:end_date].present?
        tracking_events_query = tracking_events_query.where('created_at <= ?', params[:end_date])
        print_logs_query = print_logs_query.where('printed_at <= ?', params[:end_date])
      end
      
      # Apply activity type filter
      if params[:activity_type].present?
        case params[:activity_type]
        when 'scan'
          print_logs_query = PackagePrintLog.none
        when 'print'
          tracking_events_query = PackageTrackingEvent.none
        end
      end
      
      # Fetch all data
      tracking_events = tracking_events_query.to_a
      print_logs = print_logs_query.to_a
      
      # Build activities array
      all_activities = []
      
      tracking_events.each do |event|
        begin
          all_activities << {
            id: "event_#{event.id}",
            type: 'scan',
            activity_type: event.event_type,
            description: get_event_description(event),
            package_code: event.package&.code || "PKG-#{event.package_id}",
            package_id: event.package_id,
            timestamp: event.created_at.iso8601,
            metadata: event.metadata || {},
            category: get_event_category(event)
          }
        rescue => e
          Rails.logger.error "Error formatting tracking event #{event.id}: #{e.message}"
        end
      end
      
      print_logs.each do |log|
        begin
          all_activities << {
            id: "print_#{log.id}",
            type: 'print',
            activity_type: log.print_context,
            description: get_print_log_description(log),
            package_code: log.package&.code || "PKG-#{log.package_id}",
            package_id: log.package_id,
            timestamp: log.printed_at.iso8601,
            metadata: log.metadata || {},
            copies: log.copies_printed,
            status: log.status
          }
        rescue => e
          Rails.logger.error "Error formatting print log #{log.id}: #{e.message}"
        end
      end
      
      # Sort by timestamp
      all_activities.sort_by! { |a| a[:timestamp] }.reverse!
      
      # Paginate
      total_count = all_activities.length
      start_index = (page - 1) * limit
      end_index = start_index + limit - 1
      paginated_activities = all_activities[start_index..end_index] || []
      
      render json: {
        success: true,
        data: {
          activities: paginated_activities,
          pagination: {
            current_page: page,
            total_pages: (total_count.to_f / limit).ceil,
            total_count: total_count,
            per_page: limit
          },
          summary: {
            total_activities: total_count,
            scans: tracking_events.length,
            prints: print_logs.length,
            packages_handled: (tracking_events.map(&:package_id) + print_logs.map(&:package_id)).uniq.length
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
      
      rejection_events = PackageTrackingEvent.where(
        user: current_user,
        event_type: 'rejected'
      ).includes(:package).order(created_at: :desc)
      
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
          route_description: get_package_route_description(event.package)
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
    Package.all
  end

  def apply_package_filters(query)
    query = query.where(state: params[:state]) if params[:state].present?
    query = query.where(delivery_type: params[:delivery_type]) if params[:delivery_type].present?
    query = query.where(origin_area_id: params[:origin_area_id]) if params[:origin_area_id].present?
    query = query.where(destination_area_id: params[:destination_area_id]) if params[:destination_area_id].present?
    
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
    today_start = Date.current.beginning_of_day
    today_end = Date.current.end_of_day
    
    pending_packages_count = Package.where(state: ['pending', 'pending_unpaid', 'submitted']).count
    
    {
      incoming_deliveries: pending_packages_count,
      completed_today: Package.where(state: ['delivered', 'collected'], updated_at: today_start..today_end).count,
      pending_packages: {
        total: pending_packages_count
      },
      staff_info: {
        id: current_user.id,
        name: current_user.display_name,
        role: current_user.primary_role,
        role_display: current_user.role_display_name
      },
      activity_summary: {
        scans_today: PackageTrackingEvent.where(user: current_user, created_at: today_start..today_end).count,
        prints_today: PackagePrintLog.where(user: current_user, printed_at: today_start..today_end).count,
        packages_handled_today: PackageTrackingEvent.where(user: current_user, created_at: today_start..today_end)
                                                    .select(:package_id).distinct.count
      }
    }
  rescue => e
    Rails.logger.error "Error calculating staff dashboard stats: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    
    {
      incoming_deliveries: 0,
      completed_today: 0,
      pending_packages: { total: 0 },
      staff_info: {
        id: current_user.id,
        name: current_user.display_name,
        role: current_user.primary_role,
        role_display: current_user.role_display_name
      },
      activity_summary: {
        scans_today: 0,
        prints_today: 0,
        packages_handled_today: 0
      }
    }
  end

  def format_package_for_staff(package)
    origin = package.location_based_delivery? ? (package.pickup_location.presence || 'Location-based Pickup') : (package.origin_area&.full_name || 'Unknown Origin')
    destination = package.location_based_delivery? ? (package.delivery_location.presence || 'Location-based Delivery') : (package.destination_area&.full_name || 'Unknown Destination')
    
    {
      id: package.id,
      code: package.code || "PKG-#{package.id}",
      state: package.state || 'unknown',
      state_display: (package.state || 'unknown').humanize,
      delivery_type: package.delivery_type || 'doorstep',
      delivery_type_display: package.delivery_type_display || 'Standard Delivery',
      package_size: package.package_size,
      cost: package.cost || 0,
      created_at: package.created_at,
      updated_at: package.updated_at,
      sender: {
        name: package.user&.display_name || 'Unknown',
        phone: package.user&.phone_number || 'N/A'
      },
      receiver: {
        name: package.receiver_name || 'Unknown',
        phone: package.receiver_phone || 'N/A'
      },
      route: {
        origin: origin,
        destination: destination,
        description: get_package_route_description(package)
      },
      requires_special_handling: package.respond_to?(:requires_special_handling?) ? package.requires_special_handling? : false,
      priority_level: package.priority_level || 'standard',
      can_be_rejected: ['pending', 'submitted'].include?(package.state)
    }
  rescue => e
    Rails.logger.error "Error formatting package #{package.id}: #{e.message}"
    
    {
      id: package.id,
      code: package.code || "PKG-#{package.id}",
      state: 'unknown',
      state_display: 'Unknown',
      delivery_type: 'doorstep',
      delivery_type_display: 'Standard Delivery',
      package_size: nil,
      cost: 0,
      created_at: package.created_at,
      updated_at: package.updated_at,
      sender: { name: 'Unknown', phone: 'N/A' },
      receiver: { name: 'Unknown', phone: 'N/A' },
      route: { origin: 'Unknown', destination: 'Unknown', description: 'Unknown' },
      requires_special_handling: false,
      priority_level: 'standard',
      can_be_rejected: false
    }
  end

  def format_package_details(package)
    base_details = format_package_for_staff(package)
    
    tracking_events_count = PackageTrackingEvent.where(package: package).count rescue 0
    last_scan = PackageTrackingEvent.where(package: package).order(created_at: :desc).first&.created_at rescue nil
    print_count = PackagePrintLog.where(package: package).count rescue 0
    
    base_details.merge(
      tracking_summary: {
        total_events: tracking_events_count,
        last_scan: last_scan,
        print_count: print_count
      },
      payment_info: (package.respond_to?(:requires_collection?) && package.requires_collection?) ? {
        payment_type: package.payment_type || 'prepaid',
        payment_status: package.payment_status || 'unpaid',
        collection_amount: package.collection_amount || 0,
        requires_collection: true
      } : nil,
      special_instructions: package.special_instructions,
      handling_instructions: get_handling_instructions(package),
      metadata: package.metadata || {}
    )
  rescue => e
    Rails.logger.error "Error formatting package details: #{e.message}"
    format_package_for_staff(package)
  end

  def format_tracking_event(event)
    {
      id: event.id,
      event_type: event.event_type,
      event_type_display: event.event_type.humanize,
      description: get_event_description(event),
      category: get_event_category(event),
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
      metadata: event.metadata || {},
      location: event.metadata&.dig('location')
    }
  end

  def format_print_log(log)
    {
      id: log.id,
      print_context: log.print_context,
      print_context_display: get_print_log_description(log),
      status: log.status,
      status_display: log.status&.humanize || 'Unknown',
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
      metadata: log.metadata || {}
    }
  end

  def generate_status_history(package)
    PackageTrackingEvent.where(package: package)
                        .where.not(event_type: ['scan_error', 'processing_error'])
                        .order(created_at: :asc)
                        .map do |event|
      {
        status: event.event_type,
        timestamp: event.created_at,
        description: get_event_description(event),
        user: event.user.display_name
      }
    end
  rescue => e
    Rails.logger.error "Error generating status history: #{e.message}"
    []
  end

  def calculate_estimated_delivery(package)
    return nil if package.state.in?(['delivered', 'collected'])
    
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
    when 'agent' then 'printed_by_agent'
    when 'rider' then 'collected_by_rider'
    when 'warehouse' then 'processed_by_warehouse'
    else 'state_changed'
    end
  end

  def valid_event_type_for_role?(event_type, role)
    return true if PackageTrackingEvent.respond_to?(:role_event_types)
    
    valid_events = PackageTrackingEvent.role_event_types(role) rescue ['scan', 'printed_by_agent', 'collected_by_rider', 'processed_by_warehouse', 'state_changed']
    valid_events.include?(event_type)
  rescue
    true
  end

  def get_package_route_description(package)
    return package.route_description if package.respond_to?(:route_description)
    
    origin = package.location_based_delivery? ? (package.pickup_location.presence || 'Location-based Pickup') : (package.origin_area&.full_name || 'Unknown Origin')
    destination = package.location_based_delivery? ? (package.delivery_location.presence || 'Location-based Delivery') : (package.destination_area&.full_name || 'Unknown Destination')
    "#{origin} → #{destination}"
  rescue => e
    Rails.logger.error "Error getting route description: #{e.message}"
    'Unknown route'
  end

  def get_event_description(event)
    return event.event_description if event.respond_to?(:event_description)
    event.event_type.humanize
  rescue
    'Package event'
  end

  def get_event_category(event)
    return event.event_category if event.respond_to?(:event_category)
    'general'
  rescue
    'general'
  end

  def get_print_log_description(log)
    return log.print_context_display if log.respond_to?(:print_context_display)
    log.print_context&.humanize || 'Label printed'
  rescue
    'Label printed'
  end

  def get_handling_instructions(package)
    return package.handling_instructions if package.respond_to?(:handling_instructions)
    'Standard handling'
  rescue
    'Standard handling'
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
  rescue => e
    Rails.logger.error "Error broadcasting rejection: #{e.message}"
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
        location: event.metadata&.dig('location'),
        timestamp: Time.current.iso8601
      }
    )
    
    Rails.logger.info "✅ Scan event broadcast to user #{package.user_id}"
  rescue => e
    Rails.logger.error "Error broadcasting scan event: #{e.message}"
  end

  def broadcast_staff_dashboard_update
    ActionCable.server.broadcast(
      "staff_dashboard",
      {
        type: 'dashboard_stats_update',
        stats: calculate_staff_dashboard_stats,
        timestamp: Time.current.iso8601
      }
    )
    
    Rails.logger.info "✅ Staff dashboard stats broadcast"
  rescue => e
    Rails.logger.error "Error broadcasting dashboard update: #{e.message}"
  end
end