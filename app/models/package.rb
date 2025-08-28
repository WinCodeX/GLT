# app/models/package.rb - FIXED: Handle fragile deliveries without area requirements

class Package < ApplicationRecord
  belongs_to :user
  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true
  belongs_to :origin_agent, class_name: 'Agent', optional: true
  belongs_to :destination_agent, class_name: 'Agent', optional: true

  # Enhanced tracking associations
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
  
  # ✅ FIXED: Conditional route sequence validation - not required for fragile/collect deliveries
  validates :route_sequence, presence: true, uniqueness: { 
    scope: [:origin_area_id, :destination_area_id],
    message: "Package sequence must be unique for this route"
  }, unless: :location_independent_delivery?

  # ✅ FIXED: Conditional area validations
  validates :origin_area, presence: true, unless: :location_independent_delivery?
  validates :destination_area, presence: true, unless: :location_independent_delivery?

  # Additional validation for fragile packages
  validate :fragile_package_requirements, if: :fragile?
  
  # ✅ FIXED: Validate that fragile packages have pickup and delivery locations
  validate :fragile_delivery_requirements, if: :fragile?

  # Callbacks
  before_create :generate_package_code_and_sequence
  after_create :generate_qr_code_files
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

  # ✅ FIXED: Method to handle fragile package sequences
  def self.next_fragile_sequence
    fragile_packages.maximum(:route_sequence).to_i + 1
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
    !intra_area_shipment? && origin_area_id.present? && destination_area_id.present?
  end

  def fragile?
    delivery_type == 'fragile'
  end

  # ✅ FIXED: New method to identify location-independent deliveries
  def location_independent_delivery?
    ['fragile'].include?(delivery_type)
  end

  def requires_special_handling?
    fragile?
  end

  def standard_delivery?
    ['doorstep', 'agent'].include?(delivery_type)
  end

  def route_description
    # ✅ FIXED: Handle fragile packages without area information
    if fragile?
      pickup_desc = pickup_location.present? ? pickup_location.truncate(30) : 'Pickup Location'
      delivery_desc = delivery_location.present? ? delivery_location.truncate(30) : 'Delivery Location'
      "FRAGILE: #{pickup_desc} → #{delivery_desc}"
    elsif intra_area_shipment?
      "Within #{origin_area&.name}"
    elsif origin_area && destination_area
      "#{origin_area.name} → #{destination_area.name}"
    else
      "Custom Route"
    end
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

  private

  # ✅ FIXED: Enhanced code and sequence generation for fragile packages
  def generate_package_code_and_sequence
    return if code.present? # Don't regenerate if already set
    
    # Generate code using the PackageCodeGenerator service
    generator_options = fragile? ? { fragile: true } : {}
    self.code = PackageCodeGenerator.new(self, generator_options).generate
    
    # ✅ FIXED: Set route sequence based on delivery type
    if location_independent_delivery?
      # For fragile/location-independent deliveries, use global sequence
      self.route_sequence = self.class.next_fragile_sequence
    elsif origin_area_id.present? && destination_area_id.present?
      # For standard deliveries with areas, use route-based sequence
      self.route_sequence = self.class.next_sequence_for_route(origin_area_id, destination_area_id)
    else
      # Fallback for edge cases
      self.route_sequence = Package.maximum(:route_sequence).to_i + 1
    end
  end

  def generate_qr_code_files
    # Generate both QR code types asynchronously (optional)
    job_options = fragile? ? { priority: 'high', fragile: true } : {}
    
    begin
      if defined?(GenerateQrCodeJob)
        # Generate organic QR
        GenerateQrCodeJob.perform_later(self, job_options.merge(qr_type: 'organic'))
        
        # Generate thermal QR
        GenerateThermalQrCodeJob.perform_later(self, job_options.merge(qr_type: 'thermal')) if defined?(GenerateThermalQrCodeJob)
      end
    rescue => e
      # Log error but don't fail package creation
      Rails.logger.error "Failed to generate QR codes for package #{id}: #{e.message}"
    end
  end

  def calculate_default_cost
    # Enhanced cost calculation with fragile handling
    if fragile?
      # Fragile packages have fixed pricing regardless of area
      base_cost = 1000 # KES 1,000 for fragile handling
      return base_cost
    end
    
    if intra_area_shipment?
      case delivery_type
      when 'doorstep' then 150
      when 'agent' then 100
      else 100
      end
    else
      # Inter-area shipping
      case delivery_type
      when 'doorstep' then 300
      when 'agent' then 200
      else 200
      end
    end
  end

  def apply_fragile_surcharge(base_cost)
    return base_cost unless fragile?
    
    # Fragile packages already have surcharge included in base cost
    base_cost
  end

  def fragile_package_requirements
    return unless fragile?
    
    # ✅ FIXED: Fragile-specific validations
    if cost && cost < 500
      errors.add(:cost, 'cannot be less than 500 KES for fragile packages due to special handling requirements')
    end
  end

  # ✅ FIXED: New validation for fragile delivery requirements
  def fragile_delivery_requirements
    return unless fragile?
    
    # For fragile packages, we need pickup and delivery locations instead of areas
    if pickup_location.blank? && delivery_location.blank?
      errors.add(:base, 'Fragile packages require either pickup_location or delivery_location to be specified')
    end
    
    if receiver_name.blank?
      errors.add(:receiver_name, 'is required for fragile deliveries')
    end
    
    if receiver_phone.blank?
      errors.add(:receiver_phone, 'is required for fragile deliveries')
    end
  end

  def update_fragile_metadata
    return unless fragile?
    
    # This method can be used to set additional metadata for fragile packages
    # For example, updating handling priority, special instructions, etc.
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

  def tracking_url
    begin
      Rails.application.routes.url_helpers.package_tracking_url(self.code)
    rescue
      # Fallback if route helpers aren't available
      base_url = Rails.env.production? ? 
                 (ENV['APP_URL'] || "https://#{Rails.application.config.host}") :
                 "http://localhost:3000"
      "#{base_url}/track/#{code}"
    end
  end
end