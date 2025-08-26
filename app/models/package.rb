# app/models/package.rb - Complete with all enums and proper validations
class Package < ApplicationRecord
  belongs_to :user
  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true
  belongs_to :origin_agent, class_name: 'Agent', optional: true
  belongs_to :destination_agent, class_name: 'Agent', optional: true

  # Enhanced tracking associations
  has_many :tracking_events, class_name: 'PackageTrackingEvent', dependent: :destroy
  has_many :print_logs, class_name: 'PackagePrintLog', dependent: :destroy

  # FIXED: Complete enum definitions with conflict resolution
  enum delivery_type: { 
    doorstep: 'doorstep', 
    agent: 'agent', 
    fragile: 'fragile',
    collection: 'collection'
  }
  
  enum state: {
    pending_unpaid: 'pending_unpaid',
    pending: 'pending',
    submitted: 'submitted',
    in_transit: 'in_transit',
    delivered: 'delivered',
    collected: 'collected',
    rejected: 'rejected'
  }

  # FIXED: Using suffix to avoid method conflicts with state enum
  # Available methods: payment_pending?, payment_processing?, payment_completed?, payment_failed?, payment_refunded?
  enum payment_status: {
    payment_pending: 'pending',
    payment_processing: 'processing', 
    payment_completed: 'completed',
    payment_failed: 'failed',
    payment_refunded: 'refunded'
  }, _suffix: true
  
  enum payment_method: { 
    mpesa: 'mpesa', 
    card: 'card', 
    cash: 'cash', 
    bank_transfer: 'bank_transfer' 
  }
  
  # Available methods: low_priority?, normal_priority?, high_priority?, urgent_priority?
  enum priority_level: {
    low_priority: 'low',
    normal_priority: 'normal',
    high_priority: 'high', 
    urgent_priority: 'urgent'
  }, _suffix: true
  
  enum collection_type: {
    pickup_only: 'pickup_only',
    pickup_and_deliver: 'pickup_and_deliver',
    express_collection: 'express_collection'
  }

  # FIXED: Proper validation order and conditions
  validates :delivery_type, :state, presence: true
  validates :code, presence: true, uniqueness: true, on: :update # Only validate uniqueness on update
  validates :receiver_name, :receiver_phone, presence: true
  validates :sender_name, :sender_phone, presence: true
  
  # FIXED: Only validate route_sequence if areas are present
  validates :route_sequence, presence: true, uniqueness: { 
    scope: [:origin_area_id, :destination_area_id],
    message: "Package sequence must be unique for this route"
  }, if: -> { origin_area_id.present? && destination_area_id.present? }

  # Conditional validations
  validates :destination_agent_id, presence: true, if: -> { delivery_type == 'agent' }
  validates :delivery_location, presence: true, if: -> { ['doorstep', 'fragile'].include?(delivery_type) }
  
  # Collection and fragile specific validations
  validate :collection_package_requirements, if: :collection?
  validate :fragile_package_requirements, if: :fragile?
  
  # FIXED: Enum validations with correct method names
  validates :payment_method, inclusion: { in: payment_methods.keys }, allow_nil: true
  validates :payment_status, inclusion: { in: payment_statuses.keys }, allow_nil: true
  validates :priority_level, inclusion: { in: priority_levels.keys }, allow_nil: true
  validates :collection_type, inclusion: { in: collection_types.keys }, allow_nil: true
  validates :item_value, numericality: { greater_than: 0 }, allow_nil: true

  # Callbacks
  before_create :generate_package_code_and_sequence
  before_save :set_default_cost_if_needed
  after_create :generate_qr_code_files
  before_save :update_package_metadata

  # Scopes with corrected enum references
  scope :by_route, ->(origin_id, destination_id) { 
    where(origin_area_id: origin_id, destination_area_id: destination_id) 
  }
  scope :intra_area, -> { where('origin_area_id = destination_area_id') }
  scope :inter_area, -> { where('origin_area_id != destination_area_id') }
  scope :fragile_packages, -> { where(delivery_type: 'fragile') }
  scope :collection_packages, -> { where(delivery_type: 'collection') }
  scope :standard_packages, -> { where(delivery_type: ['doorstep', 'agent']) }
  scope :requiring_special_handling, -> { where(delivery_type: ['fragile', 'collection']) }
  scope :high_priority, -> { where(priority_level: ['high', 'urgent']) }
  scope :payment_pending, -> { where(payment_status: 'pending') }

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
    return 1 if origin_area_id.blank? || destination_area_id.blank?
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
    origin_area_id.present? && destination_area_id.present? && origin_area_id == destination_area_id
  end

  def collection?
    delivery_type == 'collection'
  end

  def fragile?
    delivery_type == 'fragile'
  end

  def requires_special_handling?
    collection? || fragile? || (respond_to?(:special_handling) && special_handling?)
  end

  def can_be_collected?
    delivered? && !collected?
  end

  def collection_ready?
    collection? && ['submitted', 'in_transit'].include?(state)
  end

  def requires_payment_advance?
    collection? || (respond_to?(:requires_payment_advance) && super)
  end

  def is_high_value?
    respond_to?(:item_value) && item_value.present? && item_value > 10000
  end

  # FIXED: Enhanced state transition with collection support
  def valid_state_transition?(new_state)
    current_state = state.to_s
    
    valid_transitions = {
      'pending_unpaid' => ['pending', 'rejected'],
      'pending' => ['submitted', 'rejected'],
      'submitted' => ['in_transit', 'rejected'],
      'in_transit' => ['delivered', 'rejected'],
      'delivered' => collection? ? ['collected'] : [],
      'collected' => [], # Final state
      'rejected' => ['pending'] # Can be resubmitted
    }
    
    allowed_states = valid_transitions[current_state] || []
    allowed_states.include?(new_state)
  end

  # FIXED: Collection package validations with better error handling
  def collection_package_requirements
    return unless collection?
    
    if respond_to?(:collection_address) && collection_address.blank?
      errors.add(:collection_address, "is required for collection packages")
    end
    
    if respond_to?(:shop_name) && shop_name.blank?
      errors.add(:shop_name, "is required for collection packages")
    end
    
    if respond_to?(:items_to_collect) && items_to_collect.blank?
      errors.add(:items_to_collect, "must be specified for collection packages")
    end
    
    if respond_to?(:item_value) && (item_value.blank? || item_value <= 0)
      errors.add(:item_value, "must be present and greater than 0 for collection packages")
    end
  end

  def fragile_package_requirements
    return unless fragile?
    
    if delivery_location.blank?
      errors.add(:delivery_location, "is required for fragile packages")
    end
  end

  def update_package_metadata
    if fragile?
      if respond_to?(:priority_level=)
        self.priority_level = 'high' if priority_level.blank? || normal_priority?
      end
      if respond_to?(:special_handling=)
        self.special_handling = true
      end
    end
    
    if collection?
      if respond_to?(:requires_payment_advance=)
        self.requires_payment_advance = true
      end
      if respond_to?(:collection_type=) && collection_type.blank?
        self.collection_type = 'pickup_and_deliver'
      end
      if respond_to?(:payment_method=) && payment_method.blank?
        self.payment_method = 'mpesa'
      end
      if respond_to?(:payment_status=) && payment_status.blank?
        self.payment_status = 'pending'
      end
    end
  end

  # FIXED: Enhanced cost calculation with proper fallbacks
  def calculate_delivery_cost
    # Try to find exact price first
    if origin_area_id.present? && destination_area_id.present?
      price = Price.find_by(
        origin_area_id: origin_area_id,
        destination_area_id: destination_area_id,
        delivery_type: delivery_type
      )
      
      base_cost = price&.cost || calculate_default_cost
    else
      base_cost = calculate_default_cost
    end
    
    # Apply surcharges
    final_cost = case delivery_type
    when 'fragile'
      apply_fragile_surcharge(base_cost)
    when 'collection'
      apply_collection_surcharge(base_cost)
    else
      base_cost
    end
    
    # Apply high-value surcharge
    if is_high_value?
      value_surcharge = [item_value * 0.01, 200].min.to_i
      final_cost += value_surcharge
    end
    
    final_cost
  end

  def calculate_default_cost
    is_intra = intra_area_shipment?
    
    base_costs = {
      'doorstep' => is_intra ? 150 : 300,
      'agent' => is_intra ? 100 : 200,
      'fragile' => is_intra ? 200 : 400,
      'collection' => is_intra ? 250 : 450
    }
    
    base_costs[delivery_type] || (is_intra ? 100 : 200)
  end

  def apply_fragile_surcharge(base_cost)
    surcharge = (base_cost * 0.3).round # 30% surcharge for fragile handling
    base_cost + [surcharge, 50].max # Minimum 50 KES surcharge
  end

  def apply_collection_surcharge(base_cost)
    # Collection service includes pickup + delivery + handling
    pickup_fee = 100
    handling_fee = 50
    insurance_fee = is_high_value? ? 25 : 0
    
    base_cost + pickup_fee + handling_fee + insurance_fee
  end

  # Helper methods for cleaner enum access
  def payment_completed?
    respond_to?(:payment_completed?) && super
  end

  def payment_pending_status?
    respond_to?(:payment_pending?) && payment_pending?
  end

  def high_or_urgent_priority?
    high_priority? || urgent_priority?
  end

  def is_express_collection?
    express_collection?
  end

  # Status helper methods
  def paid?
    !pending_unpaid? && (payment_completed? || !respond_to?(:payment_status))
  end

  def trackable?
    submitted? || in_transit? || delivered? || collected?
  end

  def can_be_cancelled?
    pending_unpaid? || pending?
  end

  def can_be_edited?
    pending_unpaid? || pending?
  end

  def final_state?
    delivered? || collected? || rejected?
  end

  def needs_priority_handling?
    fragile? || collection? || is_high_value? || 
    (respond_to?(:high_priority?) && (high_priority? || urgent_priority?))
  end

  def estimated_delivery_time
    case delivery_type
    when 'fragile'
      urgent_priority? ? "Same day" : "Next day"
    when 'collection'
      express_collection? ? "Same day" : "1-2 business days"
    when 'doorstep'
      intra_area_shipment? ? "Same day" : "1-2 business days"
    when 'agent'
      intra_area_shipment? ? "2-4 hours" : "Next business day"
    else
      "1-3 business days"
    end
  end

  def display_status
    case state
    when 'pending_unpaid' then 'Awaiting Payment'
    when 'pending' then 'Payment Confirmed'
    when 'submitted' then collection? ? 'Ready for Collection' : 'Ready for Pickup'
    when 'in_transit' then collection? ? 'Being Collected' : 'In Transit'
    when 'delivered' then 'Delivered'
    when 'collected' then 'Collected'
    when 'rejected' then 'Cancelled'
    else state.humanize
    end
  end

  # FIXED: Generate package code and route sequence with better error handling
  def generate_package_code_and_sequence
    return if code.present? # Don't regenerate if already set
    
    # Generate unique code
    self.code = generate_unique_code
    
    # Set route sequence only if we have area information
    if origin_area_id.present? && destination_area_id.present?
      self.route_sequence = self.class.next_sequence_for_route(origin_area_id, destination_area_id)
    else
      self.route_sequence = 1 # Default sequence for packages without area routing
    end
  end

  def generate_unique_code
    prefix = case delivery_type
    when 'fragile' then 'FRG'
    when 'collection' then 'COL'
    when 'agent' then 'AGT'  
    when 'doorstep' then 'DST'
    else 'PKG'
    end
    
    loop do
      # Format: PREFIX-YYYYMMDD-XXXX
      date_part = Time.current.strftime('%Y%m%d')
      random_part = SecureRandom.hex(2).upcase
      code = "#{prefix}-#{date_part}-#{random_part}"
      
      break code unless self.class.exists?(code: code)
    end
  end

  def set_default_cost_if_needed
    if cost.blank? || cost.zero?
      self.cost = calculate_delivery_cost
    end
  end

  def generate_qr_code_files
    job_options = {
      priority: (fragile? || collection? || needs_priority_handling?) ? 'high' : 'normal',
      fragile: fragile?,
      collection: collection?
    }
    
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

  # Enhanced JSON serialization with collection support
  def as_json(options = {})
    result = super(options)
    
    # Always include these computed fields
    result.merge!(
      'display_status' => display_status,
      'route_description' => route_description,
      'estimated_delivery' => estimated_delivery_time,
      'is_paid' => paid?,
      'is_trackable' => trackable?,
      'can_be_cancelled' => can_be_cancelled?,
      'can_be_edited' => can_be_edited?,
      'final_state' => final_state?,
      'requires_special_handling' => requires_special_handling?,
      'can_be_collected' => can_be_collected?,
      'collection_ready' => collection_ready?,
      'needs_priority_handling' => needs_priority_handling?,
      'is_high_value' => is_high_value?,
      'requires_payment_advance' => requires_payment_advance?
    )
    
    result
  end

  def route_description
    if origin_area.present? && destination_area.present?
      origin_name = origin_area.location&.name || origin_area.name
      destination_name = destination_area.location&.name || destination_area.name
      
      if intra_area_shipment?
        "#{origin_name} (#{delivery_type.humanize})"
      else
        "#{origin_name} → #{destination_name} (#{delivery_type.humanize})"
      end
    elsif destination_area.present?
      destination_name = destination_area.location&.name || destination_area.name
      "GLT Service → #{destination_name} (#{delivery_type.humanize})"
    else
      "Direct #{delivery_type.humanize} Service"
    end
  end

  def tracking_summary
    {
      code: code,
      state: state,
      display_status: display_status,
      route: route_description,
      estimated_delivery: estimated_delivery_time,
      last_update: updated_at,
      requires_payment: requires_payment_advance?,
      payment_amount: cost,
      delivery_type: delivery_type,
      special_handling: requires_special_handling?
    }
  end
end