# app/models/package.rb - Updated with collection state
class Package < ApplicationRecord
  belongs_to :user
  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true
  belongs_to :origin_agent, class_name: 'Agent', optional: true
  belongs_to :destination_agent, class_name: 'Agent', optional: true

  # Enhanced tracking associations
  has_many :tracking_events, class_name: 'PackageTrackingEvent', dependent: :destroy
  has_many :print_logs, class_name: 'PackagePrintLog', dependent: :destroy

  enum delivery_type: { 
    doorstep: 'doorstep', 
    agent: 'agent', 
    fragile: 'fragile',
    collection: 'collection' # ADDED: Collection delivery type
  }
  
  enum state: {
    pending_unpaid: 'pending_unpaid',
    pending: 'pending',
    submitted: 'submitted',
    in_transit: 'in_transit',
    delivered: 'delivered',
    collected: 'collected', # ADDED: Collection state
    rejected: 'rejected'
  }

  validates :delivery_type, :state, :cost, presence: true
  validates :code, presence: true, uniqueness: true
  validates :route_sequence, presence: true, uniqueness: { 
    scope: [:origin_area_id, :destination_area_id],
    message: "Package sequence must be unique for this route"
  }

  # ADDED: Collection-specific validations
  validate :collection_package_requirements, if: :collection?
  validate :fragile_package_requirements, if: :fragile?

  # Callbacks
  before_create :generate_package_code_and_sequence
  after_create :generate_qr_code_files
  before_save :update_package_metadata

  # Scopes
  scope :by_route, ->(origin_id, destination_id) { 
    where(origin_area_id: origin_id, destination_area_id: destination_id) 
  }
  scope :intra_area, -> { where('origin_area_id = destination_area_id') }
  scope :inter_area, -> { where('origin_area_id != destination_area_id') }
  scope :fragile_packages, -> { where(delivery_type: 'fragile') }
  scope :collection_packages, -> { where(delivery_type: 'collection') }
  scope :standard_packages, -> { where(delivery_type: ['doorstep', 'agent']) }
  scope :requiring_special_handling, -> { where(delivery_type: ['fragile', 'collection']) }

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

  def self.packages_needing_collection
    collection_packages.where(state: ['submitted', 'in_transit'])
  end

  def self.fragile_packages_in_transit
    fragile_packages.where(state: ['submitted', 'in_transit'])
  end

  # Instance methods
  def intra_area_shipment?
    origin_area_id == destination_area_id
  end

  def collection?
    delivery_type == 'collection'
  end

  def fragile?
    delivery_type == 'fragile'
  end

  def requires_special_handling?
    collection? || fragile?
  end

  def can_be_collected?
    delivered? && !collected?
  end

  def collection_ready?
    collection? && ['submitted', 'in_transit'].include?(state)
  end

  # ADDED: Enhanced state transition with collection support
  def valid_state_transition?(new_state)
    current_state = state.to_s
    
    case current_state
    when 'pending_unpaid'
      ['pending', 'rejected'].include?(new_state)
    when 'pending'
      ['submitted', 'rejected'].include?(new_state)
    when 'submitted'
      ['in_transit', 'rejected'].include?(new_state)
    when 'in_transit'
      ['delivered', 'collected', 'rejected'].include?(new_state)
    when 'delivered'
      collection? ? ['collected'].include?(new_state) : false
    when 'collected', 'rejected'
      false # Final states
    else
      false
    end
  end

  # ADDED: Collection package validations
  def collection_package_requirements
    return unless collection?
    
    errors.add(:collection_address, "can't be blank") if respond_to?(:collection_address) && collection_address.blank?
    errors.add(:shop_name, "can't be blank") if respond_to?(:shop_name) && shop_name.blank?
    errors.add(:item_value, "must be present and greater than 0") if respond_to?(:item_value) && (!item_value || item_value <= 0)
  end

  def fragile_package_requirements
    return unless fragile?
    
    if cost && cost < 100
      errors.add(:cost, 'cannot be less than 100 KES for fragile packages due to special handling requirements')
    end
  end

  def update_package_metadata
    if fragile?
      self.priority_level = 'high' if respond_to?(:priority_level=)
      self.special_handling = true if respond_to?(:special_handling=)
    end
    
    if collection?
      self.requires_payment_advance = true if respond_to?(:requires_payment_advance=)
      self.collection_type = 'pickup_and_deliver' if respond_to?(:collection_type=)
    end
  end

  # Enhanced cost calculation
  def calculate_delivery_cost
    return 0 unless origin_area && destination_area

    # Try to find exact price first
    price = Price.find_by(
      origin_area_id: origin_area_id,
      destination_area_id: destination_area_id,
      delivery_type: delivery_type
    )

    base_cost = price&.cost || calculate_default_cost
    
    # Apply surcharges
    case delivery_type
    when 'fragile'
      apply_fragile_surcharge(base_cost)
    when 'collection'
      apply_collection_surcharge(base_cost)
    else
      base_cost
    end
  end

  def calculate_default_cost
    if intra_area_shipment?
      case delivery_type
      when 'doorstep' then 150
      when 'agent' then 100
      when 'fragile' then 200
      when 'collection' then 250 # Higher base for collection service
      else 100
      end
    else
      case delivery_type
      when 'doorstep' then 300
      when 'agent' then 200
      when 'fragile' then 400
      when 'collection' then 450 # Higher base for inter-area collection
      else 200
      end
    end
  end

  def apply_fragile_surcharge(base_cost)
    surcharge = (base_cost * 0.3).round # 30% surcharge for fragile handling
    base_cost + [surcharge, 50].max # Minimum 50 KES surcharge
  end

  def apply_collection_surcharge(base_cost)
    # Collection service includes pickup + delivery
    pickup_fee = 100
    handling_fee = 50
    base_cost + pickup_fee + handling_fee
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

  def needs_priority_handling?
    fragile? || collection? || (cost && cost > 1000)
  end

  # Generate package code and route sequence
  def generate_package_code_and_sequence
    return if code.present? # Don't regenerate if already set
    
    # Generate code using the PackageCodeGenerator service
    options = {}
    options[:fragile] = true if fragile?
    options[:collection] = true if collection?
    
    if defined?(PackageCodeGenerator)
      begin
        self.code = PackageCodeGenerator.new(self, options).generate
      rescue => e
        Rails.logger.error "PackageCodeGenerator failed: #{e.message}"
        self.code = "PKG#{SecureRandom.hex(4).upcase}"
      end
    else
      self.code = "PKG#{SecureRandom.hex(4).upcase}"
    end
    
    # Set route sequence
    self.route_sequence = self.class.next_sequence_for_route(origin_area_id, destination_area_id)
  end

  def generate_qr_code_files
    job_options = {}
    job_options[:priority] = 'high' if fragile? || collection?
    job_options[:fragile] = true if fragile?
    job_options[:collection] = true if collection?
    
    begin
      if defined?(GenerateQrCodeJob)
        GenerateQrCodeJob.perform_later(self, job_options.merge(qr_type: 'organic'))
        
        if defined?(GenerateThermalQrCodeJob)
          GenerateThermalQrCodeJob.perform_later(self, job_options.merge(qr_type: 'thermal'))
        end
      end
    rescue => e
      Rails.logger.error "Failed to generate QR codes for package #{id}: #{e.message}"
    end
  end

  # JSON serialization with collection support
  def as_json(options = {})
    result = super(options)
    
    # Always include these computed fields
    result.merge!(
      'state_display' => state&.humanize,
      'route_description' => route_description,
      'is_paid' => paid?,
      'is_trackable' => trackable?,
      'can_be_cancelled' => can_be_cancelled?,
      'final_state' => final_state?,
      'requires_special_handling' => requires_special_handling?,
      'can_be_collected' => can_be_collected?,
      'collection_ready' => collection_ready?
    )
    
    result
  end

  def route_description
    return "Unknown route" unless origin_area && destination_area
    
    origin_name = origin_area.location&.name || origin_area.name
    destination_name = destination_area.location&.name || destination_area.name
    
    if intra_area_shipment?
      "#{origin_name} (#{delivery_type.humanize})"
    else
      "#{origin_name} → #{destination_name} (#{delivery_type.humanize})"
    end
  end
end