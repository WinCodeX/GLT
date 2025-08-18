# app/services/package_scanning_service.rb - FIXED: Safe user attribute access
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

    Rails.logger.info "🔄 Executing #{action_type} action for package #{package.code} by #{safe_user_name} (#{user.primary_role})"

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

  # FIXED: Safe user name getter to handle missing name attribute
  def safe_user_name
    if user.respond_to?(:name) && user.name.present?
      user.name
    elsif user.respond_to?(:first_name) && user.respond_to?(:last_name)
      "#{user.first_name} #{user.last_name}".strip
    elsif user.respond_to?(:first_name) && user.first_name.present?
      user.first_name
    elsif user.respond_to?(:last_name) && user.last_name.present?
      user.last_name
    else
      user.email || "User ##{user.id}"
    end
  end

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
      user_operates_in_area?(package.origin_area_id)
    when 'rider'
      # Rider can collect from agent (origin) or for delivery (destination)
      user_operates_in_area?(package.origin_area_id) || 
      user_operates_in_area?(package.destination_area_id)
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
      user_operates_in_area?(package.destination_area_id)
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
      user_operates_in_area?(package.origin_area_id) || 
      user_operates_in_area?(package.destination_area_id)
    when 'warehouse'
      # Warehouse staff can print packages they have access to
      user_has_warehouse_access?
    when 'rider'
      # Rider can print delivery receipts
      user_operates_in_area?(package.destination_area_id)
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

  # FIXED: Safe area operation check
  def user_operates_in_area?(area_id)
    return false unless area_id
    return true if user.primary_role == 'admin'
    
    if user.respond_to?(:operates_in_area?)
      user.operates_in_area?(area_id)
    elsif user.respond_to?(:accessible_areas)
      user.accessible_areas.exists?(id: area_id)
    else
      # Fallback: assume user can operate in any area if no specific constraints
      true
    end
  rescue => e
    Rails.logger.error "Error checking area operation: #{e.message}"
    false
  end

  # FIXED: Safe warehouse access check
  def user_has_warehouse_access?
    return false unless user.primary_role == 'warehouse'
    
    if user.respond_to?(:warehouse_staff) && user.warehouse_staff.present?
      # Check if warehouse staff has access to package locations
      user_location_ids = user.warehouse_staff.pluck(:location_id)
      package_location_ids = [
        package.origin_area&.location_id,
        package.destination_area&.location_id
      ].compact
      
      (user_location_ids & package_location_ids).any?
    else
      # Fallback: assume warehouse users have access if no specific constraints
      true
    end
  rescue => e
    Rails.logger.error "Error checking warehouse access: #{e.message}"
    false
  end

  # FIXED: Enhanced state transitions based on user role and context
  def perform_collect_action
    old_state = package.state
    
    case user.primary_role
    when 'agent'
      # Agent collecting from sender
      new_state = 'in_transit'
      event_type = 'collected_by_agent'
      message = "Package collected from sender by agent #{safe_user_name}"
    when 'rider'
      if package.state == 'submitted'
        # Rider collecting from agent
        new_state = 'in_transit'
        event_type = 'collected_by_rider'
        message = "Package collected by rider #{safe_user_name} for delivery"
      else
        # Rider collecting for delivery from warehouse
        new_state = 'in_transit'
        event_type = 'collected_for_delivery'
        message = "Package collected by rider #{safe_user_name} for delivery"
      end
    when 'warehouse'
      # Warehouse receiving package
      new_state = 'in_transit'
      event_type = 'collected_by_warehouse'
      message = "Package received at warehouse by #{safe_user_name}"
    else
      new_state = 'in_transit'
      event_type = 'collected_by_admin'
      message = "Package collected by admin #{safe_user_name}"
    end
    
    package.update!(state: new_state)
    
    create_tracking_event(event_type, {
      collection_time: Time.current,
      collector_name: safe_user_name,
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
      rider_name: safe_user_name,
      destination_area: package.destination_area&.name,
      delivery_location: metadata['location'],
      delivery_notes: metadata['notes'],
      previous_state: old_state
    })
    
    notify_delivery_completed
    
    success_result("Package delivered successfully by #{safe_user_name}", {
      new_state: 'delivered',
      previous_state: old_state,
      message: "Package #{package.code} delivered by #{safe_user_name}"
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
      staff_name: safe_user_name,
      staff_role: user.primary_role,
      print_log_id: print_log&.id,
      print_location: metadata['location']
    })
    
    print_data = generate_print_data
    
    success_result("Package ready for printing by #{safe_user_name}", {
      print_data: print_data,
      print_log_id: print_log&.id,
      message: "Package #{package.code} label printed by #{safe_user_name} (#{user.primary_role})"
    })
  end

  def perform_confirm_receipt_action
    old_state = package.state
    package.update!(state: 'collected')
    
    create_tracking_event('confirmed_by_receiver', {
      confirmation_time: Time.current,
      receiver_name: safe_user_name,
      confirmation_location: metadata['location'],
      satisfaction_rating: metadata['rating'],
      feedback: metadata['feedback'],
      previous_state: old_state
    })
    
    update_delivery_metrics
    
    success_result("Package receipt confirmed by #{safe_user_name}", {
      new_state: 'collected',
      previous_state: old_state,
      message: "Package #{package.code} receipt confirmed by #{safe_user_name}"
    })
  end

  def perform_process_action
    create_tracking_event('processed_by_warehouse', {
      processing_time: Time.current,
      warehouse_staff_name: safe_user_name,
      processing_location: metadata['location'],
      processing_notes: metadata['notes'],
      processing_type: metadata['processing_type'] || 'general_processing'
    })
    
    success_result("Package processed successfully by #{safe_user_name}", {
      new_state: package.state,
      message: "Package #{package.code} processed by #{safe_user_name} at warehouse"
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
        staff_name: safe_user_name,
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
        printed_by: safe_user_name,
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