# app/models/package.rb - FIXED: Conditional validations for fragile and collection types
class Package < ApplicationRecord
  belongs_to :user
  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true
  belongs_to :origin_agent, class_name: 'Agent', optional: true
  belongs_to :destination_agent, class_name: 'Agent', optional: true

  # Enhanced tracking associations (add these if you create the tracking models)
  has_many :tracking_events, class_name: 'PackageTrackingEvent', dependent: :destroy
  has_many :print_logs, class_name: 'PackagePrintLog', dependent: :destroy

  enum delivery_type: { doorstep: 'doorstep', agent: 'agent', fragile: 'fragile', collection: 'collection' }
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
  
  # FIXED: Conditional validation - only for agent-based deliveries
  validates :route_sequence, presence: true, uniqueness: { 
    scope: [:origin_area_id, :destination_area_id],
    message: "Package sequence must be unique for this route"
  }, unless: :location_based_delivery?

  # FIXED: Conditional area validation - only for agent-based deliveries  
  validates :origin_area_id, :destination_area_id, presence: true, unless: :location_based_delivery?

  # Additional validation for fragile packages
  validate :fragile_package_requirements, if: :fragile?

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
  scope :collection_packages, -> { where(delivery_type: 'collection') }
  scope :standard_packages, -> { where(delivery_type: ['doorstep', 'agent']) }
  scope :location_based_packages, -> { where(delivery_type: ['fragile', 'collection']) }
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

  # FIXED: New method to identify location-based deliveries
  def location_based_delivery?
    ['fragile', 'collection'].include?(delivery_type)
  end

  # Instance methods
  def intra_area_shipment?
    return false if location_based_delivery?
    origin_area_id == destination_area_id
  end

  def route_description
    # FIXED: Handle route description for location-based deliveries
    if location_based_delivery?
      pickup = pickup_location.presence || 'Pickup Location'
      delivery = delivery_location.presence || 'Delivery Location'
      return "#{pickup} → #{delivery}"
    end
    
    return 'Route information unavailable' unless origin_area && destination_area
    
    origin_location_name = origin_area.location&.name || 'Unknown Location'
    destination_location_name = destination_area.location&.name || 'Unknown Location'
    
    if origin_area.location_id == destination_area.location_id
      "#{origin_location_name} (#{origin_area.name} → #{destination_area.name})"
    else
      "#{origin_location_name} → #{destination_location_name}"
    end
  rescue => e
    Rails.logger.error "Route description generation failed: #{e.message}"
    'Route information unavailable'
  end

  def tracking_url
    "#{Rails.application.routes.url_helpers.root_url}track/#{code}"
  rescue
    "/track/#{code}"
  end

  # FIXED: Conditional QR options based on delivery type
  def organic_qr_options
    base_options = {
      module_size: 12,
      border_size: 24,
      corner_radius: 8,
      center_logo: true,
      gradient: true,
      logo_size: 40
    }
    
    if fragile?
      base_options.merge({
        fragile_indicator: true,
        priority_handling: true,
        module_size: 14, # Larger for fragile visibility
        border_size: 28,
        corner_radius: 6
      })
    elsif delivery_type == 'collection'
      base_options.merge({
        collection_indicator: true,
        module_size: 13,
        border_size: 26
      })
    else
      base_options
    end
  end

  def thermal_qr_options
    base_options = {
      module_size: 6,
      border_size: 12,
      thermal_optimized: true,
      monochrome: true,
      corner_radius: 2
    }
    
    if fragile?
      base_options.merge({
        fragile_indicator: true,
        priority_handling: true,
        module_size: 7, # Slightly larger for fragile visibility
        border_size: 14,
        corner_radius: 4 # More organic rounding even for thermal
      })
    elsif delivery_type == 'collection'
      base_options.merge({
        collection_indicator: true,
        module_size: 6,
        border_size: 13
      })
    else
      base_options
    end
  end

  # Enhanced JSON serialization with QR options
  def as_json(options = {})
    result = super(options).except('route_sequence') # Hide internal sequence from API
    
    # Always include these computed fields
    result.merge!(
      'tracking_code' => code,
      'route_description' => route_description,
      'is_intra_area' => intra_area_shipment?,
      'tracking_url' => tracking_url,
      'is_fragile' => fragile?,
      'is_collection' => delivery_type == 'collection',
      'is_location_based' => location_based_delivery?,
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

    # Include collection-specific information
    if delivery_type == 'collection'
      result.merge!(
        'collection_instructions' => 'Package will be collected from specified pickup location',
        'collection_type' => 'Location-based collection service'
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

  def requires_special_handling?
    fragile? || delivery_type == 'collection'
  end

  def priority_level
    case delivery_type
    when 'fragile'
      'high'
    when 'collection'
      'medium'
    else
      'standard'
    end
  end

  def delivery_type_display
    case delivery_type
    when 'doorstep'
      'Doorstep Delivery'
    when 'agent'
      'Agent Pickup'
    when 'fragile'
      'Fragile Delivery'
    when 'collection'
      'Collection Service'
    else
      delivery_type.humanize
    end
  end

  def handling_instructions
    case delivery_type
    when 'fragile'
      'Handle with extreme care. This package contains fragile items.'
    when 'collection'
      'Collection service - pick up from specified location.'
    else
      'Standard handling procedures apply.'
    end
  end

  private

  # FIXED: Conditional code and sequence generation
  def generate_package_code_and_sequence
    return if code.present?
    
    # Generate code using the PackageCodeGenerator service
    generator_options = {}
    generator_options[:fragile] = true if fragile?
    generator_options[:collection] = true if delivery_type == 'collection'
    
    self.code = PackageCodeGenerator.new(self, generator_options).generate
    
    # FIXED: Only set route sequence for agent-based deliveries
    unless location_based_delivery?
      self.route_sequence = self.class.next_sequence_for_route(origin_area_id, destination_area_id)
    else
      # For location-based deliveries, use a simple incrementing sequence
      self.route_sequence = self.class.where(delivery_type: delivery_type).maximum(:route_sequence).to_i + 1
    end
  end

  def generate_qr_code_files
    # Generate both QR code types asynchronously (optional)
    job_options = {}
    job_options[:priority] = 'high' if fragile?
    job_options[:fragile] = true if fragile?
    job_options[:collection] = true if delivery_type == 'collection'
    
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

  # FIXED: Enhanced cost calculation with location-based delivery support
  def calculate_default_cost
    case delivery_type
    when 'fragile'
      500 # Premium pricing for fragile items
    when 'collection'
      350 # Collection service pricing
    when 'doorstep'
      location_based_delivery? ? 300 : (intra_area_shipment? ? 150 : 300)
    when 'agent'
      location_based_delivery? ? 200 : (intra_area_shipment? ? 100 : 200)
    else
      200
    end
  end

  def fragile_package_requirements
    return unless fragile?
    
    # Add specific validations for fragile packages
    if cost && cost < 100
      errors.add(:cost, 'cannot be less than 100 KES for fragile packages due to special handling requirements')
    end
  end

  def update_fragile_metadata
    return unless fragile?
    
    # This method can be used to set additional metadata for fragile packages
    # For example, updating handling priority, special instructions, etc.
  end
end