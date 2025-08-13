# app/models/package_tracking_event.rb
class PackageTrackingEvent < ApplicationRecord
  belongs_to :package
  belongs_to :user
  
  # Event types for different scanning actions
  EVENT_TYPES = %w[
    created
    payment_received
    submitted_for_delivery
    collected_by_rider
    in_transit
    delivered_by_rider
    confirmed_by_receiver
    printed_by_agent
    cancelled
    rejected
  ].freeze

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :package, :user, presence: true
  
  scope :recent, -> { order(created_at: :desc) }
  scope :by_event_type, ->(type) { where(event_type: type) }
  scope :for_package, ->(package) { where(package: package) }
  scope :by_user, ->(user) { where(user: user) }

  # JSON metadata structure examples:
  # {
  #   "location": { "lat": 1.2921, "lng": 36.8219, "accuracy": 10 },
  #   "device_info": { "platform": "iOS", "version": "17.0" },
  #   "scan_context": "qr_code",
  #   "additional_notes": "Package in good condition"
  # }

  def location
    metadata&.dig('location')
  end

  def has_location?
    location.present? && location['lat'].present? && location['lng'].present?
  end

  def device_info
    metadata&.dig('device_info') || {}
  end

  def scan_context
    metadata&.dig('scan_context')
  end

  def additional_notes
    metadata&.dig('additional_notes')
  end

  def user_role_at_event
    metadata&.dig('user_role') || user&.role
  end

  def formatted_timestamp
    created_at.strftime('%Y-%m-%d %H:%M:%S %Z')
  end

  def event_description
    case event_type
    when 'created'
      'Package created by customer'
    when 'payment_received'
      'Payment processed successfully'
    when 'submitted_for_delivery'
      'Package submitted for delivery'
    when 'collected_by_rider'
      "Package collected by #{user&.name || 'rider'}"
    when 'in_transit'
      'Package is in transit'
    when 'delivered_by_rider'
      "Package delivered by #{user&.name || 'rider'}"
    when 'confirmed_by_receiver'
      "Package receipt confirmed by #{user&.name || 'customer'}"
    when 'printed_by_agent'
      "Package label printed by #{user&.name || 'agent'}"
    when 'cancelled'
      'Package delivery cancelled'
    when 'rejected'
      'Package rejected'
    else
      event_type.humanize
    end
  end

  def self.create_for_scan_action(package, action_type, user, additional_metadata = {})
    event_type = map_action_to_event_type(action_type)
    return nil unless event_type

    base_metadata = {
      scan_context: 'qr_code',
      action_type: action_type,
      user_role: user.role,
      timestamp: Time.current.iso8601
    }.merge(additional_metadata)

    create!(
      package: package,
      user: user,
      event_type: event_type,
      metadata: base_metadata
    )
  end

  private

  def self.map_action_to_event_type(action_type)
    case action_type
    when 'collect'
      'collected_by_rider'
    when 'deliver'
      'delivered_by_rider'
    when 'confirm_receipt'
      'confirmed_by_receiver'
    when 'print'
      'printed_by_agent'
    else
      nil
    end
  end
end

# app/models/package_print_log.rb
class PackagePrintLog < ApplicationRecord
  belongs_to :package
  belongs_to :user
  
  validates :package, :user, :printed_at, presence: true
  validates :print_context, inclusion: { in: %w[qr_scan manual bulk_scan api] }
  
  scope :recent, -> { order(printed_at: :desc) }
  scope :by_context, ->(context) { where(print_context: context) }
  scope :for_package, ->(package) { where(package: package) }
  scope :by_user, ->(user) { where(user: user) }

  def self.log_print(package, user, context = 'manual', metadata = {})
    create!(
      package: package,
      user: user,
      printed_at: Time.current,
      print_context: context,
      metadata: metadata
    )
  end
end

# Migration file: db/migrate/[timestamp]_create_package_tracking_events.rb
class CreatePackageTrackingEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :package_tracking_events do |t|
      t.references :package, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :event_type, null: false
      t.json :metadata, default: {}
      t.datetime :event_timestamp, default: -> { 'CURRENT_TIMESTAMP' }
      
      t.timestamps
    end

    add_index :package_tracking_events, [:package_id, :created_at]
    add_index :package_tracking_events, [:event_type, :created_at]
    add_index :package_tracking_events, [:user_id, :created_at]
    add_index :package_tracking_events, :event_timestamp
  end
end

# Migration file: db/migrate/[timestamp]_create_package_print_logs.rb
class CreatePackagePrintLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :package_print_logs do |t|
      t.references :package, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.datetime :printed_at, null: false
      t.string :print_context, default: 'manual'
      t.json :metadata, default: {}
      
      t.timestamps
    end

    add_index :package_print_logs, [:package_id, :printed_at]
    add_index :package_print_logs, [:user_id, :printed_at]
    add_index :package_print_logs, :print_context
  end
end

# Update to Package model: app/models/package.rb
# Add these methods to your existing Package model:

class Package < ApplicationRecord
  # ... existing code ...
  
  has_many :tracking_events, class_name: 'PackageTrackingEvent', dependent: :destroy
  has_many :print_logs, class_name: 'PackagePrintLog', dependent: :destroy

  # Enhanced state transition methods with event tracking
  def transition_to_state!(new_state, user, metadata = {})
    return false if state == new_state
    
    old_state = state
    
    ActiveRecord::Base.transaction do
      update!(state: new_state)
      
      # Create tracking event
      event_type = state_to_event_type(new_state)
      if event_type
        tracking_events.create!(
          user: user,
          event_type: event_type,
          metadata: metadata.merge(
            previous_state: old_state,
            new_state: new_state,
            transition_context: 'state_change'
          )
        )
      end
    end
    
    true
  rescue => e
    Rails.logger.error "State transition failed: #{e.message}"
    false
  end

  # Get comprehensive tracking timeline
  def tracking_timeline(include_prints: false)
    events = tracking_events.includes(:user).recent
    
    if include_prints
      print_events = print_logs.includes(:user).map do |print_log|
        {
          type: 'print',
          timestamp: print_log.printed_at,
          user: print_log.user,
          description: "Package label printed by #{print_log.user.name}",
          metadata: print_log.metadata,
          context: print_log.print_context
        }
      end
      
      event_data = events.map do |event|
        {
          type: 'tracking',
          timestamp: event.created_at,
          user: event.user,
          description: event.event_description,
          metadata: event.metadata,
          event_type: event.event_type
        }
      end
      
      # Combine and sort by timestamp
      (event_data + print_events).sort_by { |e| e[:timestamp] }.reverse
    else
      events.map do |event|
        {
          timestamp: event.created_at,
          user: event.user,
          description: event.event_description,
          metadata: event.metadata,
          event_type: event.event_type
        }
      end
    end
  end

  # Check if package has been scanned recently
  def recently_scanned?(within: 5.minutes)
    tracking_events.where(created_at: within.ago..Time.current).exists?
  end

  # Get last scan information
  def last_scan_info
    last_event = tracking_events.where(
      event_type: ['collected_by_rider', 'delivered_by_rider', 'confirmed_by_receiver', 'printed_by_agent']
    ).recent.first
    
    return nil unless last_event
    
    {
      event_type: last_event.event_type,
      user: last_event.user,
      timestamp: last_event.created_at,
      location: last_event.location,
      metadata: last_event.metadata
    }
  end

  private

  def state_to_event_type(state)
    case state
    when 'pending'
      'payment_received'
    when 'submitted'
      'submitted_for_delivery'
    when 'in_transit'
      'in_transit'
    when 'delivered'
      'delivered_by_rider'
    when 'collected'
      'confirmed_by_receiver'
    when 'cancelled'
      'cancelled'
    when 'rejected'
      'rejected'
    else
      nil
    end
  end
end