
# app/services/package_scanning_service.rb - FIXED: Enhanced state transitions
class PackageScanningService
  include ActiveModel::Model
  include ActiveModel::Attributes

  attr_accessor :package, :user, :action_type, :metadata

  validates :package, :user, :action_type, presence: true
  validates :action_type, inclusion: { in: %w[collect deliver print confirm_receipt process] }

  def initialize(package:, user:, action_type:, metadata: {})
    @package = package
    @user = user
    @action_type = action_type
    @metadata = metadata || {}
  end

  def execute
    return failure_result('Invalid parameters') unless valid?
    return failure_result('Unauthorized action') unless authorized?
    return failure_result('Invalid package state for this action') unless valid_state_for_action?

    Rails.logger.info "🔄 Executing #{action_type} action for package #{package.code} by #{user.name} (#{user.primary_role})"

    ActiveRecord::Base.transaction do
      case action_type
      when 'collect'
        perform_collect_action
      when 'deliver'
        perform_deliver_action
      when 'print'
        perform_print_action
      when 'confirm_receipt'
        perform_confirm_receipt_action
      when 'process'
        perform_process_action
      else
        raise "Unknown action type: #{action_type}"
      end
    end
  rescue => e
    Rails.logger.error "PackageScanningService error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    failure_result("Action failed: #{e.message}")
  end

  private

  def authorized?
    case action_type
    when 'collect'
      user_can_collect?
    when 'deliver'
      user_can_deliver?
    when 'print'
      user_can_print?
    when 'confirm_receipt'
      user_can_confirm_receipt?
    when 'process'
      user_can_process?
    else
      false
    end
  end

  # FIXED: Enhanced state validation for better transitions
  def valid_state_for_action?
    case action_type
    when 'collect'
      case user.primary_role
      when 'agent'
        package.state == 'submitted' # Agent collects from sender
      when 'rider'
        ['submitted', 'in_transit'].include?(package.state) # Rider can collect from agent or for delivery
      when 'warehouse'
        ['submitted', 'in_transit'].include?(package.state) # Warehouse receives packages
      when 'admin'
        ['submitted', 'in_transit'].include?(package.state)
      else
        false
      end
    when 'deliver'
      package.state == 'in_transit'
    when 'print'
      ['pending', 'submitted', 'in_transit', 'delivered'].include?(package.state)
    when 'confirm_receipt'
      package.state == 'delivered'
    when 'process'
      ['submitted', 'in_transit'].include?(package.state)
    else
      false
    end
  end

  def user_can_collect?
    case user.primary_role
    when 'agent'
      # Agent can collect from sender if they operate in origin area
      user.operates_in_area?(package.origin_area_id)
    when 'rider'
      # Rider can collect from agent (origin) or for delivery (destination)
      user.operates_in_area?(package.origin_area_id) || 
      user.operates_in_area?(package.destination_area_id)
    when 'warehouse'
      # Warehouse staff can collect packages for processing
      user_has_warehouse_access?
    when 'admin'
      true
    else
      false
    end
  end

  def user_can_deliver?
    case user.primary_role
    when 'rider'
      # Rider can deliver in destination area
      user.operates_in_area?(package.destination_area_id)
    when 'admin'
      true
    else
      false
    end
  end

  def user_can_print?
    case user.primary_role
    when 'agent'
      # Agent can print if they operate in origin or destination area
      user.operates_in_area?(package.origin_area_id) || 
      user.operates_in_area?(package.destination_area_id)
    when 'warehouse'
      # Warehouse staff can print packages they have access to
      user_has_warehouse_access?
    when 'rider'
      # Rider can print delivery receipts
      user.operates_in_area?(package.destination_area_id)
    when 'admin'
      true
    else
      false
    end
  end

  def user_can_confirm_receipt?
    case user.primary_role
    when 'client'
      package.user_id == user.id
    when 'admin'
      true
    else
      false
    end
  end

  def user_can_process?
    case user.primary_role
    when 'warehouse'
      user_has_warehouse_access?
    when 'admin'
      true
    else
      false
    end
  end

  def user_has_warehouse_access?
    return false unless user.primary_role == 'warehouse'
    return false unless user.respond_to?(:warehouse_staff)
    
    # Check if warehouse staff has access to package locations
    user_location_ids = user.warehouse_staff.pluck(:location_id)
    package_location_ids = [
      package.origin_area&.location_id,
      package.destination_area&.location_id
    ].compact
    
    (user_location_ids & package_location_ids).any?
  end

  # FIXED: Enhanced state transitions based on user role and context
  def perform_collect_action
    old_state = package.state
    
    case user.primary_role
    when 'agent'
      # Agent collecting from sender
      new_state = 'in_transit'
      event_type = 'collected_by_agent'
      message = "Package collected from sender by agent #{user.name}"
    when 'rider'
      if package.state == 'submitted'
        # Rider collecting from agent
        new_state = 'in_transit'
        event_type = 'collected_by_rider'
        message = "Package collected by rider #{user.name} for delivery"
      else
        # Rider collecting for delivery from warehouse
        new_state = 'in_transit'
        event_type = 'collected_for_delivery'
        message = "Package collected by rider #{user.name} for delivery"
      end
    when 'warehouse'
      # Warehouse receiving package
      new_state = 'in_transit'
      event_type = 'collected_by_warehouse'
      message = "Package received at warehouse by #{user.name}"
    else
      new_state = 'in_transit'
      event_type = 'collected_by_admin'
      message = "Package collected by admin #{user.name}"
    end
    
    package.update!(state: new_state)
    
    create_tracking_event(event_type, {
      collection_time: Time.current,
      collector_name: user.name,
      collector_role: user.primary_role,
      previous_state: old_state,
      new_state: new_state,
      collection_context: determine_collection_context
    })
    
    notify_collection_completed
    
    success_result(message, {
      new_state: new_state,
      previous_state: old_state,
      message: message
    })
  end

  def perform_deliver_action
    old_state = package.state
    package.update!(state: 'delivered')
    
    create_tracking_event('delivered_by_rider', {
      delivery_time: Time.current,
      rider_name: user.name,
      destination_area: package.destination_area&.name,
      delivery_location: metadata['location'],
      delivery_notes: metadata['notes'],
      previous_state: old_state
    })
    
    notify_delivery_completed
    
    success_result("Package delivered successfully by #{user.name}", {
      new_state: 'delivered',
      previous_state: old_state,
      message: "Package #{package.code} delivered by #{user.name}"
    })
  end

  def perform_print_action
    print_log = create_print_log
    
    event_type = case user.primary_role
    when 'warehouse'
      'printed_by_warehouse'
    when 'agent'
      'printed_by_agent'
    when 'rider'
      'printed_by_rider'
    else
      'printed_by_admin'
    end
    
    create_tracking_event(event_type, {
      print_time: Time.current,
      staff_name: user.name,
      staff_role: user.primary_role,
      print_log_id: print_log&.id,
      print_location: metadata['location']
    })
    
    print_data = generate_print_data
    
    success_result("Package ready for printing by #{user.name}", {
      print_data: print_data,
      print_log_id: print_log&.id,
      message: "Package #{package.code} label printed by #{user.name} (#{user.primary_role})"
    })
  end

  def perform_confirm_receipt_action
    old_state = package.state
    package.update!(state: 'collected')
    
    create_tracking_event('confirmed_by_receiver', {
      confirmation_time: Time.current,
      receiver_name: user.name,
      confirmation_location: metadata['location'],
      satisfaction_rating: metadata['rating'],
      feedback: metadata['feedback'],
      previous_state: old_state
    })
    
    update_delivery_metrics
    
    success_result("Package receipt confirmed by #{user.name}", {
      new_state: 'collected',
      previous_state: old_state,
      message: "Package #{package.code} receipt confirmed by #{user.name}"
    })
  end

  def perform_process_action
    create_tracking_event('processed_by_warehouse', {
      processing_time: Time.current,
      warehouse_staff_name: user.name,
      processing_location: metadata['location'],
      processing_notes: metadata['notes'],
      processing_type: metadata['processing_type'] || 'general_processing'
    })
    
    success_result("Package processed successfully by #{user.name}", {
      new_state: package.state,
      message: "Package #{package.code} processed by #{user.name} at warehouse"
    })
  end

  def determine_collection_context
    case user.primary_role
    when 'agent'
      'collection_from_sender'
    when 'rider'
      package.state == 'submitted' ? 'collection_from_agent' : 'collection_for_delivery'
    when 'warehouse'
      'warehouse_receipt'
    else
      'admin_collection'
    end
  end

  def create_print_log
    return nil unless defined?(PackagePrintLog)
    
    PackagePrintLog.create!(
      package: package,
      user: user,
      printed_at: Time.current,
      print_context: metadata['bulk_operation'] ? 'bulk_scan' : 'qr_scan',
      metadata: {
        printer_info: metadata['printer_info'],
        location: metadata['location'],
        staff_name: user.name,
        staff_role: user.primary_role,
        scan_context: 'qr_code'
      }
    )
  rescue => e
    Rails.logger.error "Failed to create print log: #{e.message}"
    nil
  end

  def create_tracking_event(event_type, event_metadata = {})
    return unless defined?(PackageTrackingEvent)
    
    base_metadata = {
      scan_context: 'qr_code',
      action_type: action_type,
      user_role: user.primary_role,
      timestamp: Time.current.iso8601,
      device_info: metadata['device_info'],
      offline_sync: metadata['offline_sync']
    }.merge(event_metadata).merge(metadata.except('device_info'))

    PackageTrackingEvent.create!(
      package: package,
      user: user,
      event_type: event_type,
      metadata: base_metadata
    )
  rescue => e
    Rails.logger.error "Failed to create tracking event: #{e.message}"
  end

  def generate_print_data
    {
      package_code: package.code,
      route: package.route_description,
      sender: {
        name: package.sender_name,
        phone: package.sender_phone
      },
      receiver: {
        name: package.receiver_name,
        phone: package.receiver_phone
      },
      delivery_info: {
        type: package.delivery_type,
        cost: package.cost,
        origin_area: package.origin_area&.name,
        destination_area: package.destination_area&.name,
        origin_agent: package.origin_agent&.name,
        destination_agent: package.destination_agent&.name,
        delivery_location: package.delivery_location
      },
      print_info: {
        printed_by: user.name,
        printed_by_role: user.primary_role,
        printed_at: Time.current.strftime('%Y-%m-%d %H:%M:%S'),
        print_station: metadata['print_station'] || metadata['location'] || 'Mobile App'
      },
      qr_code_data: package.tracking_url
    }
  end

  def notify_collection_completed
    if defined?(NotificationService)
      NotificationService.new(package).notify_collection_started
    end
  rescue => e
    Rails.logger.error "Collection notification failed: #{e.message}"
  end

  def notify_delivery_completed
    if defined?(NotificationService)
      NotificationService.new(package).notify_delivery_completed
    end
  rescue => e
    Rails.logger.error "Delivery notification failed: #{e.message}"
  end

  def update_delivery_metrics
    if defined?(RiderMetrics)
      RiderMetrics.update_delivery_stats(user, package)
    end
  rescue => e
    Rails.logger.error "Metrics update failed: #{e.message}"
  end

  def success_result(message, data = {})
    {
      success: true,
      message: message,
      data: data,
      package: package,
      user: user,
      action_type: action_type,
      timestamp: Time.current
    }
  end

  def failure_result(message, error_code = nil)
    {
      success: false,
      message: message,
      error_code: error_code,
      package: package&.code,
      user: user&.id,
      action_type: action_type,
      timestamp: Time.current
    }
  end
end