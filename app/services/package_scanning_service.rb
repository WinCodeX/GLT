# app/services/package_scanning_service.rb
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
    return failure_result('Invalid package state') unless valid_state?

    Rails.logger.info "Executing #{action_type} action for package #{package.code} by #{user.name} (#{user.role})"

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

  def valid_state?
    case action_type
    when 'collect'
      package.state == 'submitted'
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
    case user.role
    when 'rider'
      # Check if rider operates in the origin area
      return false unless user.respond_to?(:riders)
      user.riders.joins(:area).where(area_id: package.origin_area_id).exists?
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
    case user.role
    when 'rider'
      # Check if rider operates in the destination area
      return false unless user.respond_to?(:riders)
      user.riders.joins(:area).where(area_id: package.destination_area_id).exists?
    when 'admin'
      true
    else
      false
    end
  end

  def user_can_print?
    case user.role
    when 'agent'
      # Check if agent operates in either origin or destination area
      return false unless user.respond_to?(:agents)
      user_area_ids = user.agents.pluck(:area_id)
      user_area_ids.include?(package.origin_area_id) || 
      user_area_ids.include?(package.destination_area_id)
    when 'warehouse'
      # Warehouse staff can print packages they have access to
      user_has_warehouse_access?
    when 'admin'
      true
    else
      false
    end
  end

  def user_can_confirm_receipt?
    case user.role
    when 'client'
      package.user_id == user.id
    when 'admin'
      true
    else
      false
    end
  end

  def user_can_process?
    case user.role
    when 'warehouse'
      user_has_warehouse_access?
    when 'admin'
      true
    else
      false
    end
  end

  def user_has_warehouse_access?
    return false unless user.role == 'warehouse'
    return false unless user.respond_to?(:warehouse_staff)
    
    # Check if warehouse staff has access to package locations
    user_location_ids = user.warehouse_staff.pluck(:location_id)
    package_location_ids = [
      package.origin_area&.location_id,
      package.destination_area&.location_id
    ].compact
    
    (user_location_ids & package_location_ids).any?
  end

  def perform_collect_action
    # Update package state
    old_state = package.state
    package.update!(state: 'in_transit')
    
    # Create tracking event
    event_type = user.role == 'warehouse' ? 'collected_by_warehouse' : 'collected_by_rider'
    create_tracking_event(event_type, {
      collection_time: Time.current,
      collector_name: user.name,
      collector_role: user.role,
      origin_area: package.origin_area&.name,
      collection_location: metadata['location'],
      previous_state: old_state
    })
    
    # Send notifications
    notify_collection_completed
    
    success_result("Package collected successfully by #{user.name}", {
      new_state: 'in_transit',
      message: "Package #{package.code} collected by #{user.name} (#{user.role})"
    })
  end

  def perform_deliver_action
    # Update package state
    old_state = package.state
    package.update!(state: 'delivered')
    
    # Create tracking event
    create_tracking_event('delivered_by_rider', {
      delivery_time: Time.current,
      rider_name: user.name,
      destination_area: package.destination_area&.name,
      delivery_location: metadata['location'],
      delivery_notes: metadata['notes'],
      previous_state: old_state
    })
    
    # Send notifications
    notify_delivery_completed
    
    success_result("Package delivered successfully by #{user.name}", {
      new_state: 'delivered',
      message: "Package #{package.code} delivered by #{user.name}"
    })
  end

  def perform_print_action
    # Log the print action
    print_log = create_print_log
    
    # Create tracking event
    event_type = user.role == 'warehouse' ? 'printed_by_warehouse' : 'printed_by_agent'
    create_tracking_event(event_type, {
      print_time: Time.current,
      staff_name: user.name,
      staff_role: user.role,
      print_log_id: print_log&.id,
      print_location: metadata['location']
    })
    
    # Generate print data
    print_data = generate_print_data
    
    success_result("Package ready for printing by #{user.name}", {
      print_data: print_data,
      print_log_id: print_log&.id,
      message: "Package #{package.code} label printed by #{user.name} (#{user.role})"
    })
  end

  def perform_confirm_receipt_action
    # Update package state
    old_state = package.state
    package.update!(state: 'collected')
    
    # Create tracking event
    create_tracking_event('confirmed_by_receiver', {
      confirmation_time: Time.current,
      receiver_name: user.name,
      confirmation_location: metadata['location'],
      satisfaction_rating: metadata['rating'],
      feedback: metadata['feedback'],
      previous_state: old_state
    })
    
    # Update delivery metrics
    update_delivery_metrics
    
    success_result("Package receipt confirmed by #{user.name}", {
      new_state: 'collected',
      message: "Package #{package.code} receipt confirmed by #{user.name}"
    })
  end

  def perform_process_action
    # Warehouse processing - could be sorting, weighing, etc.
    # For now, we'll keep the state the same but log the processing
    
    # Create tracking event
    create_tracking_event('processed_by_warehouse', {
      processing_time: Time.current,
      warehouse_staff_name: user.name,
      processing_location: metadata['location'],
      processing_notes: metadata['notes'],
      processing_type: metadata['processing_type'] || 'general_processing'
    })
    
    success_result("Package processed successfully by #{user.name}", {
      new_state: package.state, # State doesn't change for processing
      message: "Package #{package.code} processed by #{user.name} at warehouse"
    })
  end

  def create_print_log
    return nil unless defined?(PackagePrintLog)
    
    PackagePrintLog.create!(
      package: package,
      user: user,
      printed_at: Time.current,
      print_context: 'qr_scan',
      metadata: {
        printer_info: metadata['printer_info'],
        location: metadata['location'],
        staff_name: user.name,
        staff_role: user.role
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
      user_role: user.role,
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
        destination_agent: package.destination_agent&.name
      },
      print_info: {
        printed_by: user.name,
        printed_by_role: user.role,
        printed_at: Time.current.strftime('%Y-%m-%d %H:%M:%S'),
        print_station: metadata['print_station'] || metadata['location'] || 'Unknown'
      },
      qr_code_data: package.tracking_url
    }
  end

  def notify_collection_completed
    # Send SMS/email to customer about collection
    if defined?(NotificationService)
      NotificationService.new(package).notify_collection_started
    end
  rescue => e
    Rails.logger.error "Collection notification failed: #{e.message}"
  end

  def notify_delivery_completed
    # Send SMS/email to customer about delivery
    if defined?(NotificationService)
      NotificationService.new(package).notify_delivery_completed
    end
  rescue => e
    Rails.logger.error "Delivery notification failed: #{e.message}"
  end

  def update_delivery_metrics
    # Update rider performance metrics
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