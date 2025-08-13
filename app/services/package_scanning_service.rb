# app/services/package_scanning_service.rb
class PackageScanningService
  include ActiveModel::Model
  include ActiveModel::Attributes

  attr_accessor :package, :user, :action_type, :metadata

  validates :package, :user, :action_type, presence: true
  validates :action_type, inclusion: { in: %w[collect deliver print confirm_receipt] }

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
      ['submitted', 'in_transit', 'delivered'].include?(package.state)
    when 'confirm_receipt'
      package.state == 'delivered'
    else
      false
    end
  end

  def user_can_collect?
    return false unless user.role == 'rider'
    
    # Check if rider operates in the origin area
    user.riders.joins(:area).where(area_id: package.origin_area_id).exists?
  end

  def user_can_deliver?
    return false unless user.role == 'rider'
    
    # Check if rider operates in the destination area
    user.riders.joins(:area).where(area_id: package.destination_area_id).exists?
  end

  def user_can_print?
    return false unless user.role == 'agent'
    
    # Check if agent operates in either origin or destination area
    user_area_ids = user.agents.pluck(:area_id)
    user_area_ids.include?(package.origin_area_id) || 
    user_area_ids.include?(package.destination_area_id)
  end

  def user_can_confirm_receipt?
    package.user_id == user.id
  end

  def perform_collect_action
    # Update package state
    package.update!(state: 'in_transit')
    
    # Create tracking event
    create_tracking_event('collected_by_rider', {
      collection_time: Time.current,
      rider_name: user.name,
      origin_area: package.origin_area&.name,
      collection_location: metadata['location']
    })
    
    # Send notifications
    notify_collection_completed
    
    success_result('Package collected successfully', {
      new_state: 'in_transit',
      message: "Package #{package.code} collected by #{user.name}"
    })
  end

  def perform_deliver_action
    # Update package state
    package.update!(state: 'delivered')
    
    # Create tracking event
    create_tracking_event('delivered_by_rider', {
      delivery_time: Time.current,
      rider_name: user.name,
      destination_area: package.destination_area&.name,
      delivery_location: metadata['location'],
      delivery_notes: metadata['notes']
    })
    
    # Send notifications
    notify_delivery_completed
    
    success_result('Package delivered successfully', {
      new_state: 'delivered',
      message: "Package #{package.code} delivered by #{user.name}"
    })
  end

  def perform_print_action
    # Log the print action
    print_log = PackagePrintLog.create!(
      package: package,
      user: user,
      printed_at: Time.current,
      print_context: 'qr_scan',
      metadata: {
        printer_info: metadata['printer_info'],
        location: metadata['location'],
        agent_name: user.name
      }
    )
    
    # Create tracking event
    create_tracking_event('printed_by_agent', {
      print_time: Time.current,
      agent_name: user.name,
      print_log_id: print_log.id
    })
    
    # Generate print data
    print_data = generate_print_data
    
    success_result('Package ready for printing', {
      print_data: print_data,
      print_log_id: print_log.id,
      message: "Package #{package.code} label printed by #{user.name}"
    })
  end

  def perform_confirm_receipt_action
    # Update package state
    package.update!(state: 'collected')
    
    # Create tracking event
    create_tracking_event('confirmed_by_receiver', {
      confirmation_time: Time.current,
      receiver_name: user.name,
      confirmation_location: metadata['location'],
      satisfaction_rating: metadata['rating'],
      feedback: metadata['feedback']
    })
    
    # Update delivery metrics
    update_delivery_metrics
    
    success_result('Package receipt confirmed', {
      new_state: 'collected',
      message: "Package #{package.code} receipt confirmed by #{user.name}"
    })
  end

  def create_tracking_event(event_type, event_metadata = {})
    base_metadata = {
      scan_context: 'qr_code',
      action_type: action_type,
      user_role: user.role,
      timestamp: Time.current.iso8601,
      device_info: metadata['device_info']
    }.merge(event_metadata).merge(metadata.except('device_info'))

    PackageTrackingEvent.create!(
      package: package,
      user: user,
      event_type: event_type,
      metadata: base_metadata
    )
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
        printed_at: Time.current.strftime('%Y-%m-%d %H:%M:%S'),
        print_station: metadata['print_station'] || 'Unknown'
      },
      qr_code_data: package.tracking_url
    }
  end

  def notify_collection_completed
    # Send SMS/email to customer about collection
    NotificationService.new(package).notify_collection_started if defined?(NotificationService)
  rescue => e
    Rails.logger.error "Collection notification failed: #{e.message}"
  end

  def notify_delivery_completed
    # Send SMS/email to customer about delivery
    NotificationService.new(package).notify_delivery_completed if defined?(NotificationService)
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

# app/services/bulk_scanning_service.rb
class BulkScanningService
  include ActiveModel::Model

  attr_accessor :package_codes, :action_type, :user, :metadata

  validates :package_codes, :action_type, :user, presence: true
  validates :action_type, inclusion: { in: %w[collect deliver print confirm_receipt] }

  def initialize(package_codes:, action_type:, user:, metadata: {})
    @package_codes = Array(package_codes).uniq
    @action_type = action_type
    @user = user
    @metadata = metadata || {}
  end

  def execute
    return failure_result('Invalid parameters') unless valid?
    return failure_result('No packages provided') if package_codes.empty?

    results = []
    successful_count = 0
    failed_count = 0

    package_codes.each do |package_code|
      result = process_single_package(package_code)
      results << result
      
      if result[:success]
        successful_count += 1
      else
        failed_count += 1
      end
    end

    {
      success: true,
      message: "Processed #{successful_count} of #{package_codes.length} packages",
      data: {
        results: results,
        summary: {
          total: package_codes.length,
          successful: successful_count,
          failed: failed_count
        }
      }
    }
  rescue => e
    Rails.logger.error "BulkScanningService error: #{e.message}"
    failure_result("Bulk scanning failed: #{e.message}")
  end

  private

  def process_single_package(package_code)
    package = Package.find_by(code: package_code)
    
    unless package
      return {
        package_code: package_code,
        success: false,
        message: 'Package not found'
      }
    end

    scanning_service = PackageScanningService.new(
      package: package,
      user: user,
      action_type: action_type,
      metadata: metadata
    )

    result = scanning_service.execute

    {
      package_code: package_code,
      success: result[:success],
      message: result[:message],
      new_state: result[:success] ? package.reload.state : nil,
      error_code: result[:error_code]
    }
  rescue => e
    Rails.logger.error "Single package processing failed for #{package_code}: #{e.message}"
    {
      package_code: package_code,
      success: false,
      message: "Processing failed: #{e.message}"
    }
  end

  def failure_result(message, error_code = nil)
    {
      success: false,
      message: message,
      error_code: error_code,
      timestamp: Time.current
    }
  end
end