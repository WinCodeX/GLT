# app/models/package.rb
class Package < ApplicationRecord
  belongs_to :user
  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true
  belongs_to :origin_agent, class_name: 'Agent', optional: true
  belongs_to :destination_agent, class_name: 'Agent', optional: true

  # Enhanced tracking associations (add these if you create the tracking models)
  has_many :tracking_events, class_name: 'PackageTrackingEvent', dependent: :destroy
  has_many :print_logs, class_name: 'PackagePrintLog', dependent: :destroy

  enum delivery_type: { doorstep: 'doorstep', agent: 'agent', fragile: 'fragile' }
  enum state: {
    pending_unpaid: 'pending_unpaid',
    pending: 'pending',
    submitted: 'submitted',
    in_transit: 'in_transit',
    delivered: 'delivered',
    collected: 'collected',
    rejected: 'rejected'
  }

  validates :delivery_type, :state, :cost, presence: true
  validates :code, presence: true, uniqueness: true
  validates :route_sequence, presence: true, uniqueness: { 
    scope: [:origin_area_id, :destination_area_id],
    message: "Package sequence must be unique for this route"
  }

  # Additional validation for fragile packages
  validate :fragile_package_requirements, if: :fragile?

  # Callbacks
  before_create :generate_package_code_and_sequence
  after_create :generate_qr_code_file
  before_save :update_fragile_metadata, if: :fragile?

  # Scopes
  scope :by_route, ->(origin_id, destination_id) { 
    where(origin_area_id: origin_id, destination_area_id: destination_id) 
  }
  scope :intra_area, -> { where('origin_area_id = destination_area_id') }
  scope :inter_area, -> { where('origin_area_id != destination_area_id') }
  scope :fragile_packages, -> { where(delivery_type: 'fragile') }
  scope :standard_packages, -> { where(delivery_type: ['doorstep', 'agent']) }
  scope :requiring_special_handling, -> { fragile_packages }

  # Class methods
  def self.find_by_code_or_id(identifier)
    identifier = identifier.to_s.strip
    
    # Try by code first (customer-facing)
    package = find_by(code: identifier)
    
    # Fallback to ID if numeric (internal use)
    package ||= find_by(id: identifier) if identifier.match?(/^\d+$/)
    
    package
  end

  def self.next_sequence_for_route(origin_area_id, destination_area_id)
    by_route(origin_area_id, destination_area_id).maximum(:route_sequence).to_i + 1
  end

  def self.fragile_packages_in_transit
    fragile_packages.where(state: ['submitted', 'in_transit'])
  end

  def self.fragile_packages_needing_special_attention
    fragile_packages.where(state: ['submitted', 'in_transit'])
                    .joins(:tracking_events)
                    .where(tracking_events: { created_at: 2.hours.ago.. })
                    .group('packages.id')
                    .having('COUNT(package_tracking_events.id) = 0')
  end

  # Instance methods
  def intra_area_shipment?
    origin_area_id == destination_area_id
  end

  def inter_area_shipment?
    !intra_area_shipment?
  end

  def fragile?
    delivery_type == 'fragile'
  end

  def requires_special_handling?
    fragile?
  end

  def standard_delivery?
    ['doorstep', 'agent'].include?(delivery_type)
  end

  def route_description
    base_description = if intra_area_shipment?
                        "Within #{origin_area&.name}"
                      else
                        "#{origin_area&.name} → #{destination_area&.name}"
                      end
    
    fragile? ? "#{base_description} (FRAGILE)" : base_description
  end

  def display_identifier
    identifier = "#{code} (#{route_description})"
    fragile? ? "⚠️ #{identifier}" : identifier
  end

  def delivery_type_display
    case delivery_type
    when 'doorstep'
      'Door-to-Door Delivery'
    when 'agent'
      'Agent Collection'
    when 'fragile'
      '⚠️ Fragile Handling Required'
    else
      delivery_type.humanize
    end
  end

  def handling_instructions
    return [] unless fragile?
    
    [
      'Handle with extreme care',
      'Avoid dropping or throwing',
      'Keep upright at all times',
      'Use protective packaging',
      'Prioritize gentle transport',
      'Check for damage before and after handling'
    ]
  end

  def priority_level
    case delivery_type
    when 'fragile'
      'HIGH'
    when 'doorstep'
      'MEDIUM'
    when 'agent'
      'STANDARD'
    else
      'STANDARD'
    end
  end

  # QR Code methods
  def generate_qr_code(options = {})
    # Add fragile indicator to QR code options
    enhanced_options = fragile? ? options.merge(fragile_indicator: true) : options
    QrCodeGenerator.new(self, enhanced_options).generate
  end

  def qr_code_base64(options = {})
    enhanced_options = fragile? ? options.merge(fragile_indicator: true) : options
    QrCodeGenerator.new(self, enhanced_options).generate_base64
  end

  def qr_code_path(options = {})
    enhanced_options = fragile? ? options.merge(fragile_indicator: true) : options
    QrCodeGenerator.new(self, enhanced_options).generate_and_save
  end

  def tracking_url
    Rails.application.routes.url_helpers.package_tracking_url(self.code)
  rescue
    # Fallback if route helpers aren't available
    "#{Rails.application.config.force_ssl ? 'https' : 'http'}://#{Rails.application.config.host}/track/#{code}"
  end

  # Enhanced JSON serialization
  def as_json(options = {})
    result = super(options).except('route_sequence') # Hide internal sequence from API
    
    # Always include these computed fields
    result.merge!(
      'tracking_code' => code,
      'route_description' => route_description,
      'is_intra_area' => intra_area_shipment?,
      'tracking_url' => tracking_url,
      'is_fragile' => fragile?,
      'requires_special_handling' => requires_special_handling?,
      'priority_level' => priority_level,
      'delivery_type_display' => delivery_type_display
    )
    
    # Include fragile-specific information
    if fragile?
      result.merge!(
        'handling_instructions' => handling_instructions,
        'fragile_warning' => 'This package requires special handling due to fragile contents'
      )
    end
    
    # Optionally include QR code
    if options[:include_qr_code]
      qr_options = options[:qr_options] || {}
      result['qr_code_base64'] = qr_code_base64(qr_options)
    end
    
    # Include status information
    if options[:include_status]
      result.merge!(
        'status_display' => state.humanize,
        'is_paid' => !pending_unpaid?,
        'is_in_transit' => in_transit?,
        'is_delivered' => delivered? || collected?,
        'can_be_handled_roughly' => !fragile?
      )
    end
    
    result
  end

  # Status helper methods
  def paid?
    !pending_unpaid?
  end

  def trackable?
    submitted? || in_transit? || delivered? || collected?
  end

  def can_be_cancelled?
    pending_unpaid? || pending?
  end

  def final_state?
    delivered? || collected? || rejected?
  end

  def can_be_handled_roughly?
    !fragile?
  end

  def needs_priority_handling?
    fragile? || (cost > 1000) # High value or fragile packages get priority
  end

  # Enhanced state transition methods with fragile package considerations
  def transition_to_state!(new_state, user, metadata = {})
    return false if state == new_state
    
    old_state = state
    
    # Add fragile package specific metadata
    if fragile?
      metadata = metadata.merge(
        fragile_package: true,
        handling_instructions: handling_instructions,
        priority_level: priority_level
      )
    end
    
    ActiveRecord::Base.transaction do
      update!(state: new_state)
      
      # Create tracking event if tracking is enabled
      if defined?(PackageTrackingEvent)
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
      
      # Send special notifications for fragile packages
      if fragile? && ['in_transit', 'delivered'].include?(new_state)
        send_fragile_package_notification(new_state, user)
      end
    end
    
    true
  rescue => e
    Rails.logger.error "State transition failed: #{e.message}"
    false
  end

  # Calculate sequence for existing packages (used in migration)
  def calculate_route_sequence
    Package.where(
      origin_area_id: origin_area_id,
      destination_area_id: destination_area_id
    ).where('created_at < ?', created_at || Time.current)
     .count + 1
  end

  # Search methods
  def self.search_by_code(query)
    where("code ILIKE ?", "%#{query}%")
  end

  def self.for_user_routes(user)
    # Get packages for areas where user has agents
    user_agent_area_ids = user.agents.pluck(:area_id)
    where(
      origin_area_id: user_agent_area_ids
    ).or(
      where(destination_area_id: user_agent_area_ids)
    )
  end

  # Enhanced cost calculation with fragile handling fees
  def calculate_delivery_cost
    return 0 unless origin_area && destination_area

    price = Price.find_by(
      origin_area_id: origin_area_id,
      destination_area_id: destination_area_id,
      origin_agent_id: origin_agent_id,
      destination_agent_id: destination_agent_id,
      delivery_type: delivery_type
    )

    base_cost = price&.cost || calculate_default_cost
    
    # Add fragile handling surcharge
    fragile? ? apply_fragile_surcharge(base_cost) : base_cost
  end

  def update_cost!
    new_cost = calculate_delivery_cost
    update!(cost: new_cost) if new_cost != cost
  end

  def fragile_surcharge_amount
    return 0 unless fragile?
    
    # Calculate surcharge as percentage of base cost (minimum 50 KES)
    base_cost = calculate_default_cost
    surcharge = (base_cost * 0.25).round # 25% surcharge for fragile
    [surcharge, 50].max # Minimum 50 KES surcharge
  end

  def base_cost_without_fragile_surcharge
    fragile? ? cost - fragile_surcharge_amount : cost
  end

  # Get comprehensive tracking timeline including fragile-specific events
  def tracking_timeline(include_prints: false)
    return [] unless defined?(PackageTrackingEvent)
    
    events = tracking_events.includes(:user).recent
    
    timeline_data = events.map do |event|
      {
        timestamp: event.created_at,
        user: event.user,
        description: event.event_description,
        metadata: event.metadata,
        event_type: event.event_type,
        is_fragile_related: fragile? && event.metadata['fragile_package']
      }
    end
    
    if include_prints && defined?(PackagePrintLog)
      print_events = print_logs.includes(:user).map do |print_log|
        {
          type: 'print',
          timestamp: print_log.printed_at,
          user: print_log.user,
          description: "#{fragile? ? 'Fragile package' : 'Package'} label printed by #{print_log.user.name}",
          metadata: print_log.metadata,
          context: print_log.print_context,
          is_fragile_related: fragile?
        }
      end
      
      timeline_data.concat(print_events)
    end
    
    timeline_data.sort_by { |e| e[:timestamp] }.reverse
  end

  # Check if package has been scanned recently (fragile packages get shorter intervals)
  def recently_scanned?(within: nil)
    return false unless defined?(PackageTrackingEvent)
    
    time_window = within || (fragile? ? 2.hours : 5.minutes)
    tracking_events.where(created_at: time_window.ago..Time.current).exists?
  end

  # Get last scan information with fragile context
  def last_scan_info
    return nil unless defined?(PackageTrackingEvent)
    
    last_event = tracking_events.where(
      event_type: ['collected_by_rider', 'delivered_by_rider', 'confirmed_by_receiver', 'printed_by_agent']
    ).recent.first
    
    return nil unless last_event
    
    {
      event_type: last_event.event_type,
      user: last_event.user,
      timestamp: last_event.created_at,
      location: last_event.location,
      metadata: last_event.metadata,
      was_fragile_at_scan: last_event.metadata['fragile_package'] || false,
      handling_notes: last_event.metadata['handling_notes']
    }
  end

  private

  def generate_package_code_and_sequence
    return if code.present? # Don't regenerate if already set
    
    # Generate code using the PackageCodeGenerator service
    # Pass fragile indicator to code generator for special handling
    generator_options = fragile? ? { fragile: true } : {}
    self.code = PackageCodeGenerator.new(self, generator_options).generate
    
    # Set route sequence
    self.route_sequence = self.class.next_sequence_for_route(origin_area_id, destination_area_id)
  end

  def generate_qr_code_file
    # Generate and save QR code file asynchronously (optional)
    # Pass fragile context to job
    if defined?(GenerateQrCodeJob)
      job_options = fragile? ? { priority: 'high', fragile: true } : {}
      GenerateQrCodeJob.perform_later(self, job_options)
    end
  rescue => e
    # Log error but don't fail package creation
    Rails.logger.error "Failed to generate QR code for package #{id}: #{e.message}"
  end

  def calculate_default_cost
    # Enhanced cost calculation with fragile handling
    if intra_area_shipment?
      case delivery_type
      when 'doorstep' then 150
      when 'agent' then 100
      when 'fragile' then 175  # Higher base cost for fragile items
      else 100
      end
    else
      # Inter-area shipping
      case delivery_type
      when 'doorstep' then 300
      when 'agent' then 200
      when 'fragile' then 350  # Significantly higher for inter-area fragile
      else 200
      end
    end
  end

  def apply_fragile_surcharge(base_cost)
    return base_cost unless fragile?
    
    # Apply additional surcharge beyond the base fragile cost
    surcharge = fragile_surcharge_amount
    base_cost + surcharge
  end

  def fragile_package_requirements
    return unless fragile?
    
    # Add specific validations for fragile packages
    if cost && cost < 100
      errors.add(:cost, 'cannot be less than 100 KES for fragile packages due to special handling requirements')
    end
    
    # Could add other fragile-specific validations here
    # e.g., certain areas might not support fragile delivery
  end

  def update_fragile_metadata
    return unless fragile?
    
    # This method can be used to set additional metadata for fragile packages
    # For example, updating handling priority, special instructions, etc.
  end

  def send_fragile_package_notification(new_state, user)
    # Send special notifications for fragile package state changes
    # This would integrate with your notification system
    Rails.logger.info "Fragile package #{code} transitioned to #{new_state} by #{user.name}"
    
    # Example: Send SMS to customer about fragile package status
    # FragilePackageNotificationService.new(self, new_state, user).send_notification
  end

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