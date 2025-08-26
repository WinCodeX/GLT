# app/models/package.rb - UPDATED: Origin agent is optional
class Package < ApplicationRecord
  belongs_to :user
  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true
  belongs_to :origin_agent, class_name: 'Agent', optional: true # UPDATED: Made optional
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

  # UPDATED: Origin agent is optional but available
  validates :delivery_type, :state, presence: true
  validates :code, presence: true, uniqueness: true, on: :update
  validates :receiver_name, :receiver_phone, presence: true
  validates :sender_name, :sender_phone, presence: true
  
  # Only validate route_sequence if origin_area and destination_area are present
  validates :route_sequence, presence: true, uniqueness: { 
    scope: [:origin_area_id, :destination_area_id],
    message: "Package sequence must be unique for this route"
  }, if: -> { origin_area_id.present? && destination_area_id.present? }

  # Delivery type specific validations
  validates :destination_agent_id, presence: true, if: -> { delivery_type == 'agent' }
  validates :delivery_location, presence: true, if: -> { ['doorstep', 'fragile'].include?(delivery_type) }

  # Additional validation for fragile packages
  validate :fragile_package_requirements, if: :fragile?
  
  # Collection service validations
  validates :shop_name, :shop_contact, :collection_address, :items_to_collect, :item_value, 
            presence: true, if: -> { collection_type.present? }

  # Callbacks
  before_create :generate_package_code_and_sequence
  after_create :generate_qr_code_files
  before_save :update_fragile_metadata, if: :fragile?
  before_save :set_default_cost

  # Scopes
  scope :by_route, ->(origin_id, destination_id) { 
    where(origin_area_id: origin_id, destination_area_id: destination_id) 
  }
  scope :intra_area, -> { where('origin_area_id = destination_area_id') }
  scope :inter_area, -> { where('origin_area_id != destination_area_id') }
  scope :fragile_packages, -> { where(delivery_type: 'fragile') }
  scope :standard_packages, -> { where(delivery_type: ['doorstep', 'agent']) }
  scope :requiring_special_handling, -> { fragile_packages }
  scope :collection_services, -> { where.not(collection_type: nil) }

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
    origin_area_id.present? && destination_area_id.present? && 
    origin_area_id == destination_area_id
  end

  def inter_area_shipment?
    origin_area_id.present? && destination_area_id.present? && 
    origin_area_id != destination_area_id
  end

  def requires_agent_pickup?
    # Origin agent is used when package needs to be picked up from a specific agent location
    # This is optional - packages can be created without origin agents for direct customer submissions
    origin_agent_id.present?
  end

  def requires_agent_delivery?
    delivery_type == 'agent' && destination_agent_id.present?
  end

  def is_collection_service?
    collection_type.present?
  end

  def estimated_delivery_time
    case delivery_type
    when 'fragile'
      return "Same day" if priority_level == 'urgent'
      return "Next day" if priority_level == 'high'
      "1-2 business days"
    when 'doorstep'
      return intra_area_shipment? ? "Same day" : "1-2 business days"
    when 'agent'
      return intra_area_shipment? ? "2-4 hours" : "Next business day"
    else
      "1-3 business days"
    end
  end

  def display_route
    if origin_area.present? && destination_area.present?
      "#{origin_area.name} → #{destination_area.name}"
    elsif destination_area.present?
      "GLT Service → #{destination_area.name}"
    else
      "Direct Delivery"
    end
  end

  def display_status
    case state
    when 'pending_unpaid'
      'Awaiting Payment'
    when 'pending'
      'Payment Confirmed'
    when 'submitted'
      'Ready for Pickup'
    when 'in_transit'
      'In Transit'
    when 'delivered'
      'Delivered'
    when 'collected'
      'Collected'
    when 'rejected'
      'Cancelled'
    else
      state.humanize
    end
  end

  def can_be_cancelled?
    ['pending_unpaid', 'pending'].include?(state)
  end

  def can_be_edited?
    ['pending_unpaid', 'pending'].include?(state)
  end

  def requires_payment?
    ['pending_unpaid'].include?(state) || requires_payment_advance?
  end

  def payment_amount
    return cost if cost.present? && cost > 0
    calculate_cost
  end

  def is_high_value?
    item_value.present? && item_value > 10000
  end

  def tracking_summary
    {
      code: code,
      state: state,
      display_status: display_status,
      route: display_route,
      estimated_delivery: estimated_delivery_time,
      last_update: updated_at,
      requires_payment: requires_payment?,
      payment_amount: payment_amount
    }
  end

  private

  def fragile_package_requirements
    if fragile? && delivery_location.blank?
      errors.add(:delivery_location, "is required for fragile deliveries")
    end
    
    if fragile? && special_instructions.blank?
      errors.add(:special_instructions, "should include handling instructions for fragile items")
    end
  end

  def generate_package_code_and_sequence
    self.code = generate_unique_code if code.blank?
    
    # Only set route sequence if we have area information
    if origin_area_id.present? && destination_area_id.present?
      self.route_sequence = self.class.next_sequence_for_route(origin_area_id, destination_area_id)
    else
      self.route_sequence = 1 # Default for packages without area routing
    end
  end

  def generate_unique_code
    prefix = case delivery_type
    when 'fragile'
      'FRG'
    when 'agent'
      'AGT'  
    when 'doorstep'
      'DST'
    else
      'PKG'
    end
    
    # Add collection service prefix
    prefix = "COL-#{prefix}" if collection_type.present?
    
    loop do
      # Format: PREFIX-YYYYMMDD-XXXX
      date_part = Time.current.strftime('%Y%m%d')
      random_part = SecureRandom.hex(2).upcase
      code = "#{prefix}-#{date_part}-#{random_part}"
      
      break code unless self.class.exists?(code: code)
    end
  end

  def generate_qr_code_files
    # Generate QR code for package tracking
    # Implementation would depend on your QR code generation setup
    Rails.logger.info "📱 QR code generation for package #{code}"
  end

  def update_fragile_metadata
    if fragile?
      self.special_handling = true
      self.priority_level = 'high' if priority_level.blank? || priority_level == 'normal'
    end
  end

  def set_default_cost
    self.cost = calculate_cost if cost.blank? || cost.zero?
  end

  def calculate_cost
    base_cost = case delivery_type
    when 'fragile'
      300
    when 'agent'
      150
    when 'doorstep'
      200
    else
      200
    end

    # Add collection service cost
    base_cost += 150 if collection_type == 'pickup_and_deliver'

    # Distance-based pricing (if we have area information)
    if origin_area_id.present? && destination_area_id.present?
      base_cost += 50 unless intra_area_shipment?
    end

    # Priority surcharge
    case priority_level
    when 'high'
      base_cost += 50
    when 'urgent'
      base_cost += 100
    end

    # Special handling surcharge
    base_cost += 75 if special_handling?

    # High-value item surcharge
    if is_high_value?
      base_cost += [item_value * 0.01, 200].min.to_i
    end

    base_cost
  end
end