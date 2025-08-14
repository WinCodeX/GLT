# app/models/package_tracking_event.rb
class PackageTrackingEvent < ApplicationRecord
  belongs_to :package
  belongs_to :user

  # Event types for different scanning actions
  enum event_type: {
    # Package lifecycle events
    created: 'created',
    payment_received: 'payment_received',
    submitted_for_delivery: 'submitted_for_delivery',
    
    # Agent actions
    printed_by_agent: 'printed_by_agent',
    
    # Rider actions
    collected_by_rider: 'collected_by_rider',
    delivered_by_rider: 'delivered_by_rider',
    
    # Warehouse actions
    collected_by_warehouse: 'collected_by_warehouse',
    processed_by_warehouse: 'processed_by_warehouse',
    printed_by_warehouse: 'printed_by_warehouse',
    sorted_by_warehouse: 'sorted_by_warehouse',
    
    # Customer actions
    confirmed_by_receiver: 'confirmed_by_receiver',
    
    # System events
    state_changed: 'state_changed',
    cancelled: 'cancelled',
    rejected: 'rejected',
    
    # Error events
    scan_error: 'scan_error',
    processing_error: 'processing_error'
  }

  # Validations
  validates :event_type, presence: true
  validates :metadata, presence: true
  validates :package, presence: true
  validates :user, presence: true

  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :today, -> { where(created_at: Date.current.all_day) }
  scope :this_week, -> { where(created_at: 1.week.ago..Time.current) }
  scope :this_month, -> { where(created_at: 1.month.ago..Time.current) }
  scope :by_user, ->(user) { where(user: user) }
  scope :by_package, ->(package) { where(package: package) }
  scope :by_event_type, ->(event_type) { where(event_type: event_type) }
  scope :by_role, ->(role) { joins(:user).where(users: { role: role }) }
  scope :scanning_events, -> { where(event_type: scanning_event_types) }
  scope :user_actions, -> { where.not(event_type: ['created', 'state_changed']) }

  # Callbacks
  before_validation :set_default_metadata
  after_create :update_package_state, if: :state_changing_event?
  after_create :notify_stakeholders, if: :notification_event?

  # Class methods
  def self.scanning_event_types
    [
      'printed_by_agent',
      'collected_by_rider',
      'delivered_by_rider',
      'collected_by_warehouse',
      'processed_by_warehouse',
      'printed_by_warehouse',
      'confirmed_by_receiver'
    ]
  end

  def self.role_event_types(role)
    case role.to_s
    when 'agent'
      ['printed_by_agent']
    when 'rider'
      ['collected_by_rider', 'delivered_by_rider']
    when 'warehouse'
      ['collected_by_warehouse', 'processed_by_warehouse', 'printed_by_warehouse', 'sorted_by_warehouse']
    when 'client'
      ['confirmed_by_receiver']
    when 'admin'
      event_types.keys
    else
      []
    end
  end

  def self.create_scan_event(package:, user:, event_type:, metadata: {})
    create!(
      package: package,
      user: user,
      event_type: event_type,
      metadata: default_scan_metadata.merge(metadata)
    )
  end

  def self.create_bulk_scan_events(packages:, user:, event_type:, metadata: {})
    events = []
    
    packages.each do |package|
      events << new(
        package: package,
        user: user,
        event_type: event_type,
        metadata: default_scan_metadata.merge(metadata).merge(
          bulk_operation: true,
          package_code: package.code
        )
      )
    end
    
    import(events, validate: true)
    events
  end

  def self.default_scan_metadata
    {
      scan_context: 'qr_code',
      timestamp: Time.current.iso8601,
      app_version: Rails.application.class.module_parent_name,
      scan_method: 'mobile_app'
    }
  end

  def self.events_summary(start_date: 1.month.ago, end_date: Time.current)
    events = where(created_at: start_date..end_date)
    
    {
      total_events: events.count,
      unique_packages: events.select(:package_id).distinct.count,
      unique_users: events.select(:user_id).distinct.count,
      events_by_type: events.group(:event_type).count,
      events_by_role: events.joins(:user).group('users.role').count,
      events_by_day: events.group_by_day(:created_at).count,
      scanning_events: events.scanning_events.count,
      error_events: events.where(event_type: ['scan_error', 'processing_error']).count
    }
  end

  # Instance methods
  def scanning_event?
    self.class.scanning_event_types.include?(event_type)
  end

  def error_event?
    ['scan_error', 'processing_error'].include?(event_type)
  end

  def state_changing_event?
    event_type_to_state.present?
  end

  def notification_event?
    ['delivered_by_rider', 'confirmed_by_receiver', 'cancelled', 'rejected'].include?(event_type)
  end

  def bulk_operation?
    metadata['bulk_operation'] == true
  end

  def offline_sync?
    metadata['offline_sync'] == true
  end

  def event_description
    base_description = case event_type
    when 'printed_by_agent'
      "Package label printed by #{user.name}"
    when 'collected_by_rider'
      "Package collected by rider #{user.name}"
    when 'delivered_by_rider'
      "Package delivered by rider #{user.name}"
    when 'collected_by_warehouse'
      "Package collected by warehouse staff #{user.name}"
    when 'processed_by_warehouse'
      "Package processed in warehouse by #{user.name}"
    when 'printed_by_warehouse'
      "Package label printed in warehouse by #{user.name}"
    when 'confirmed_by_receiver'
      "Package receipt confirmed by #{user.name}"
    when 'cancelled'
      "Package cancelled by #{user.name}"
    when 'rejected'
      "Package rejected by #{user.name}"
    else
      "#{event_type.humanize} by #{user.name}"
    end

    # Add additional context
    context_parts = []
    context_parts << "Offline sync" if offline_sync?
    context_parts << "Bulk operation" if bulk_operation?
    context_parts << "Location: #{metadata['location']}" if metadata['location']
    
    if context_parts.any?
      "#{base_description} (#{context_parts.join(', ')})"
    else
      base_description
    end
  end

  def event_category
    case event_type
    when 'printed_by_agent', 'printed_by_warehouse'
      'printing'
    when 'collected_by_rider', 'collected_by_warehouse'
      'collection'
    when 'delivered_by_rider'
      'delivery'
    when 'processed_by_warehouse', 'sorted_by_warehouse'
      'processing'
    when 'confirmed_by_receiver'
      'confirmation'
    when 'cancelled', 'rejected'
      'cancellation'
    when 'scan_error', 'processing_error'
      'error'
    else
      'system'
    end
  end

  def location_info
    location_data = metadata['location']
    return nil unless location_data

    if location_data.is_a?(Hash)
      {
        latitude: location_data['latitude'],
        longitude: location_data['longitude'],
        accuracy: location_data['accuracy'],
        address: location_data['address']
      }
    else
      { address: location_data.to_s }
    end
  end

  def device_info
    device_data = metadata['device_info']
    return nil unless device_data.is_a?(Hash)

    {
      platform: device_data['platform'],
      app_version: device_data['app_version'],
      device_model: device_data['device_model']
    }
  end

  def processing_time
    return nil unless metadata['processing_time']
    
    metadata['processing_time'].to_f
  end

  def was_successful?
    !error_event? && metadata['success'] != false
  end

  def error_message
    return nil unless error_event?
    
    metadata['error_message'] || metadata['message']
  end

  def related_events
    package.tracking_events
           .where.not(id: id)
           .where(created_at: (created_at - 1.hour)..(created_at + 1.hour))
           .recent
  end

  def next_expected_event
    case event_type
    when 'printed_by_agent'
      'collected_by_rider'
    when 'collected_by_rider'
      'delivered_by_rider'
    when 'delivered_by_rider'
      'confirmed_by_receiver'
    when 'processed_by_warehouse'
      'collected_by_rider'
    else
      nil
    end
  end

  def time_since_creation
    Time.current - created_at
  end

  def formatted_timestamp
    created_at.strftime('%Y-%m-%d %H:%M:%S %Z')
  end

  # JSON serialization
  def as_json(options = {})
    result = super(options.except(:include_package, :include_user, :include_location))
    
    result.merge!(
      'event_description' => event_description,
      'event_category' => event_category,
      'was_successful' => was_successful?,
      'time_since_creation' => time_since_creation,
      'formatted_timestamp' => formatted_timestamp,
      'scanning_event' => scanning_event?,
      'bulk_operation' => bulk_operation?,
      'offline_sync' => offline_sync?
    )

    # Include package info if requested
    if options[:include_package]
      result['package'] = {
        id: package.id,
        code: package.code,
        state: package.state,
        route_description: package.route_description
      }
    end

    # Include user info if requested
    if options[:include_user]
      result['user'] = {
        id: user.id,
        name: user.name,
        role: user.role,
        role_display: user.role_display_name
      }
    end

    # Include location info if requested and available
    if options[:include_location] && location_info
      result['location'] = location_info
    end

    result
  end

  private

  def set_default_metadata
    self.metadata ||= {}
    self.metadata = self.class.default_scan_metadata.merge(metadata)
  end

  def update_package_state
    new_state = event_type_to_state
    return unless new_state && package.state != new_state

    old_state = package.state
    package.update_column(:state, new_state)
    
    # Log the state change
    Rails.logger.info "Package #{package.code} state changed from #{old_state} to #{new_state} due to event #{event_type}"
  end

  def event_type_to_state
    case event_type
    when 'payment_received'
      'pending'
    when 'submitted_for_delivery'
      'submitted'
    when 'collected_by_rider', 'collected_by_warehouse'
      'in_transit'
    when 'delivered_by_rider'
      'delivered'
    when 'confirmed_by_receiver'
      'collected'
    when 'cancelled'
      'cancelled'
    when 'rejected'
      'rejected'
    else
      nil
    end
  end

  def notify_stakeholders
    # This would integrate with your notification system
    case event_type
    when 'delivered_by_rider'
      # Notify customer about delivery
      NotificationService.new(package).notify_delivery_completed if defined?(NotificationService)
    when 'confirmed_by_receiver'
      # Notify sender about confirmation
      NotificationService.new(package).notify_receipt_confirmed if defined?(NotificationService)
    end
  rescue => e
    Rails.logger.error "Failed to send notification for event #{id}: #{e.message}"
  end
end