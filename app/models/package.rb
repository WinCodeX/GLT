# app/models/package.rb - Add the missing enums and fix methods
class Package < ApplicationRecord
  belongs_to :user
  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true
  belongs_to :origin_agent, class_name: 'Agent', optional: true
  belongs_to :destination_agent, class_name: 'Agent', optional: true

  # Enhanced tracking associations
  has_many :tracking_events, class_name: 'PackageTrackingEvent', dependent: :destroy
  has_many :print_logs, class_name: 'PackagePrintLog', dependent: :destroy

  # FIXED: Add missing enums
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
  
  # ADD: Missing priority_level enum
  enum priority_level: { 
    low: 'low', 
    normal: 'normal', 
    high: 'high', 
    urgent: 'urgent' 
  }
  
  # ADD: Payment method enum
  enum payment_method: {
    cash: 'cash',
    mpesa: 'mpesa',
    bank: 'bank',
    card: 'card'
  }

  validates :delivery_type, :state, :cost, presence: true
  validates :code, presence: true, uniqueness: true
  validates :route_sequence, presence: true, uniqueness: { 
    scope: [:origin_area_id, :destination_area_id],
    message: "Package sequence must be unique for this route"
  }
  
  # ADD: Validation for priority level - default to normal if not set
  validates :priority_level, presence: true
  validates :payment_method, presence: true

  # Additional validation for fragile packages
  validate :fragile_package_requirements, if: :fragile?

  # Callbacks
  before_create :generate_package_code_and_sequence
  after_create :generate_qr_code_files
  before_save :update_package_metadata  # FIXED: Changed from update_fragile_metadata
  before_validation :set_default_values

  # Scopes
  scope :by_route, ->(origin_id, destination_id) { 
    where(origin_area_id: origin_id, destination_area_id: destination_id) 
  }
  scope :intra_area, -> { where('origin_area_id = destination_area_id') }
  scope :inter_area, -> { where('origin_area_id != destination_area_id') }
  scope :fragile_packages, -> { where(delivery_type: 'fragile') }
  scope :standard_packages, -> { where(delivery_type: ['doorstep', 'agent']) }
  scope :requiring_special_handling, -> { fragile_packages }
  scope :priority_packages, -> { where(priority_level: ['high', 'urgent']) }

  # FIXED: Add the missing update_package_metadata method
  def update_package_metadata
    # Set fragile-specific metadata
    if fragile?
      self.priority_level = 'high' if normal_priority? || low_priority?
      
      # Add fragile handling fee if not already calculated
      if cost_changed? || new_record?
        self.cost = calculate_delivery_cost_with_surcharge
      end
      
      # Set special handling flag
      self.special_handling = true
      
      # Add handling instructions if not present
      if item_description.present? && !handling_instructions.present?
        self.handling_instructions = "FRAGILE: #{item_description} - Handle with extra care"
      end
    end
    
    # Set default priority if not set
    self.priority_level ||= 'normal'
    
    # Set default payment method if not set
    self.payment_method ||= 'mpesa'
  end

  # FIXED: Set default values before validation
  def set_default_values
    self.priority_level ||= 'normal'
    self.payment_method ||= 'mpesa'
    self.special_handling ||= fragile?
    self.requires_payment_advance ||= false
  end

  # Instance methods
  def intra_area_shipment?
    origin_area_id == destination_area_id
  end

  def route_description
    if intra_area_shipment?
      "Within #{origin_area&.name || 'Unknown Area'}"
    else
      "#{origin_area&.name || 'Unknown'} → #{destination_area&.name || 'Unknown'}"
    end
  end

  def tracking_url
    "#{Rails.application.routes.url_helpers.root_url}track/#{code}"
  end

  def requires_special_handling?
    fragile? || priority_level.in?(['high', 'urgent']) || special_handling?
  end

  def delivery_type_display
    case delivery_type
    when 'doorstep' then 'Door-to-Door'
    when 'agent' then 'Agent Pickup'
    when 'fragile' then 'Fragile Handling'
    else delivery_type.humanize
    end
  end

  def handling_instructions
    return read_attribute(:handling_instructions) if has_attribute?(:handling_instructions)
    
    # Generate default handling instructions if column doesn't exist
    if fragile?
      instructions = ["FRAGILE ITEM - Handle with care"]
      instructions << "Item: #{item_description}" if item_description.present?
      instructions << "Special: #{special_instructions}" if special_instructions.present?
      instructions.join(" | ")
    else
      special_instructions.presence
    end
  end

  # Enhanced cost calculation with fragile handling fees
  def calculate_delivery_cost
    return 0 unless origin_area && destination_area

    # Try to find specific pricing
    price = Price.find_by(
      origin_area_id: origin_area_id,
      destination_area_id: destination_area_id,
      origin_agent_id: origin_agent_id,
      destination_agent_id: destination_agent_id,
      delivery_type: delivery_type
    )

    price&.cost || calculate_default_cost
  end
  
  def calculate_delivery_cost_with_surcharge
    base_cost = calculate_delivery_cost
    
    # Add fragile handling surcharge
    if fragile?
      base_cost += fragile_surcharge_amount
    end
    
    # Add priority handling surcharge
    if high_priority? || urgent_priority?
      base_cost += priority_surcharge_amount
    end
    
    base_cost
  end

  def calculate_default_cost
    # Enhanced cost calculation with fragile handling
    if intra_area_shipment?
      case delivery_type
      when 'doorstep' then 150
      when 'agent' then 100
      when 'fragile' then 200  # Higher base cost for fragile items
      else 100
      end
    else
      # Inter-area shipping
      case delivery_type
      when 'doorstep' then 300
      when 'agent' then 200
      when 'fragile' then 400  # Significantly higher for inter-area fragile
      else 200
      end
    end
  end
  
  def fragile_surcharge_amount
    return 0 unless fragile?
    
    if intra_area_shipment?
      50  # KES 50 surcharge for local fragile
    else
      100 # KES 100 surcharge for inter-area fragile
    end
  end
  
  def priority_surcharge_amount
    case priority_level
    when 'high' then 30
    when 'urgent' then 80
    else 0
    end
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
    !fragile? && !high_priority? && !urgent_priority?
  end

  def needs_priority_handling?
    fragile? || high_priority? || urgent_priority? || (cost && cost > 1000)
  end

  # Enhanced JSON serialization
  def as_json(options = {})
    result = super(options).except('route_sequence')
    
    result.merge!(
      'tracking_code' => code,
      'route_description' => route_description,
      'is_intra_area' => intra_area_shipment?,
      'tracking_url' => tracking_url,
      'is_fragile' => fragile?,
      'requires_special_handling' => requires_special_handling?,
      'priority_level' => priority_level,
      'priority_display' => priority_level.humanize,
      'payment_method_display' => payment_method.humanize,
      'delivery_type_display' => delivery_type_display,
      'handling_instructions' => handling_instructions
    )
    
    # Include fragile-specific information
    if fragile?
      result.merge!(
        'fragile_warning' => 'This package requires special handling due to fragile contents',
        'fragile_surcharge' => fragile_surcharge_amount,
        'priority_surcharge' => priority_surcharge_amount
      )
    end
    
    result
  end

  private

  def fragile_package_requirements
    return unless fragile?
    
    # Add specific validations for fragile packages
    if cost && cost < 150
      errors.add(:cost, 'cannot be less than 150 KES for fragile packages due to special handling requirements')
    end
  end

  def generate_package_code_and_sequence
    return if code.present? # Don't regenerate if already set
    
    # Generate code with fragile prefix for fragile packages
    if fragile?
      self.code = "FRG-#{Time.current.strftime('%Y%m%d')}-#{SecureRandom.hex(2).upcase}"
    else
      self.code = "PKG-#{Time.current.strftime('%Y%m%d')}-#{SecureRandom.hex(2).upcase}"
    end
    
    # Ensure uniqueness
    while Package.exists?(code: code)
      if fragile?
        self.code = "FRG-#{Time.current.strftime('%Y%m%d')}-#{SecureRandom.hex(2).upcase}"
      else
        self.code = "PKG-#{Time.current.strftime('%Y%m%d')}-#{SecureRandom.hex(2).upcase}"
      end
    end
    
    # Set route sequence
    self.route_sequence = self.class.next_sequence_for_route(origin_area_id, destination_area_id)
  end

  def generate_qr_code_files
    # Generate QR codes asynchronously if jobs are available
    # This is optional and won't break if job classes don't exist
    begin
      if defined?(GenerateQrCodeJob)
        job_options = fragile? ? { priority: 'high', fragile: true } : {}
        GenerateQrCodeJob.perform_later(self, job_options)
      end
    rescue => e
      Rails.logger.error "Failed to generate QR codes for package #{id}: #{e.message}"
    end
  end

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
end