# app/models/package.rb - Fixed callbacks and validation handling
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
    collection: 'collection',
    express: 'express',
    bulk: 'bulk'
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

  validates :delivery_type, presence: true
  validates :sender_name, :receiver_name, :sender_phone, :receiver_phone, presence: true
  validates :code, presence: true, uniqueness: true, allow_blank: false
  validates :cost, presence: true, numericality: { greater_than: 0 }
  validates :route_sequence, presence: true, numericality: { greater_than: 0 }
  validates :state, presence: true

  # Enhanced validation for fragile packages
  validate :fragile_package_requirements, if: :fragile?
  validate :collection_package_requirements, if: :collection?

  # FIXED: Proper callback ordering and initialization
  before_validation :set_default_state, on: :create
  before_validation :generate_package_code_and_sequence, on: :create
  before_validation :calculate_and_set_cost, on: :create
  
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
  scope :requiring_special_handling, -> { where(delivery_type: ['fragile', 'collection', 'express']) }

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

  def self.collection_packages_pending
    collection_packages.where(state: ['pending_unpaid', 'pending'])
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

  def collection?
    delivery_type == 'collection'
  end

  def requires_special_handling?
    ['fragile', 'collection', 'express'].include?(delivery_type)
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
    
    case delivery_type
    when 'fragile'
      "#{base_description} (FRAGILE)"
    when 'collection'
      "#{base_description} (COLLECTION SERVICE)"
    when 'express'
      "#{base_description} (EXPRESS)"
    else
      base_description
    end
  end

  def display_identifier
    icon = case delivery_type
           when 'fragile' then '⚠️'
           when 'collection' then '📦'
           when 'express' then '⚡'
           else ''
           end
    
    identifier = "#{code} (#{route_description})"
    icon.present? ? "#{icon} #{identifier}" : identifier
  end

  def delivery_type_display
    case delivery_type
    when 'doorstep'
      'Door-to-Door Delivery'
    when 'agent'
      'Agent Collection'
    when 'fragile'
      '⚠️ Fragile Handling Required'
    when 'collection'
      '📦 Collection & Delivery Service'
    when 'express'
      '⚡ Express Delivery'
    when 'bulk'
      '📚 Bulk Package'
    else
      delivery_type.humanize
    end
  end

  def handling_instructions
    case delivery_type
    when 'fragile'
      [
        'Handle with extreme care',
        'Avoid dropping or throwing',
        'Keep upright at all times',
        'Use protective packaging',
        'Prioritize gentle transport',
        'Check for damage before and after handling'
      ]
    when 'collection'
      [
        'Verify items match collection list',
        'Get confirmation from shop owner',
        'Document any discrepancies',
        'Handle collected items carefully',
        'Confirm payment status before collection'
      ]
    when 'express'
      [
        'Priority handling required',
        'Fast-track processing',
        'Same-day delivery target',
        'Update tracking frequently'
      ]
    else
      ['Standard handling procedures apply']
    end
  end

  def priority_level
    case delivery_type
    when 'fragile', 'express'
      'HIGH'
    when 'collection'
      'MEDIUM'
    when 'doorstep'
      'MEDIUM'
    when 'agent'
      'STANDARD'
    else
      'STANDARD'
    end
  end

  # Enhanced cost calculation with delivery type considerations
  def calculate_delivery_cost
    base_cost = calculate_default_cost
    
    # Apply delivery type-specific adjustments
    case delivery_type
    when 'fragile'
      base_cost = apply_fragile_surcharge(base_cost)
    when 'collection'
      base_cost = apply_collection_fees(base_cost)
    when 'express'
      base_cost = apply_express_surcharge(base_cost)
    end
    
    base_cost
  end

  def calculate_default_cost
    if intra_area_shipment?
      case delivery_type
      when 'doorstep' then 150
      when 'agent' then 100
      when 'fragile' then 200  # Higher base cost for fragile items
      when 'collection' then 250  # Collection service fee
      when 'express' then 300  # Express handling
      when 'bulk' then 80
      else 100
      end
    else
      # Inter-area shipping
      case delivery_type
      when 'doorstep' then 300
      when 'agent' then 200
      when 'fragile' then 400  # Significantly higher for inter-area fragile
      when 'collection' then 450  # Inter-area collection
      when 'express' then 500  # Inter-area express
      when 'bulk' then 150
      else 200
      end
    end
  end

  def apply_fragile_surcharge(base_cost)
    # 20% surcharge for fragile handling
    surcharge = (base_cost * 0.20).round
    base_cost + surcharge
  end

  def apply_collection_fees(base_cost)
    # Additional fees for collection service
    collection_fee = 100  # Base collection fee
    insurance_fee = 50   # Basic insurance
    base_cost + collection_fee + insurance_fee
  end

  def apply_express_surcharge(base_cost)
    # 50% surcharge for express delivery
    surcharge = (base_cost * 0.50).round
    base_cost + surcharge
  end

  private

  # FIXED: Proper default state initialization
  def set_default_state
    self.state ||= 'pending_unpaid'
    Rails.logger.info "🔧 Set default state: #{self.state}"
  end

  # FIXED: Proper code and sequence generation with error handling
  def generate_package_code_and_sequence
    return if self.code.present? # Don't regenerate if already set
    
    begin
      # Generate code using the enhanced PackageCodeGenerator service
      generator_options = {
        delivery_type: delivery_type,
        fragile: fragile?,
        collection: collection?
      }
      
      self.code = PackageCodeGenerator.new(self, generator_options).generate
      
      # Set route sequence if not already set
      if self.route_sequence.blank?
        if origin_area_id && destination_area_id
          self.route_sequence = self.class.next_sequence_for_route(origin_area_id, destination_area_id)
        else
          # Fallback sequence for packages without proper area setup
          self.route_sequence = Time.current.to_i % 1000
        end
      end
      
      Rails.logger.info "🏷️ Generated code: #{self.code}, sequence: #{self.route_sequence}"
      
    rescue => e
      Rails.logger.error "Code generation failed: #{e.message}"
      # Fallback code generation
      self.code = "PKG-#{SecureRandom.hex(4).upcase}-#{Time.current.strftime('%Y%m%d')}"
      self.route_sequence = 1
    end
  end

  # FIXED: Proper cost calculation with validation
  def calculate_and_set_cost
    return if self.cost.present? && self.cost > 0 # Don't recalculate if already set properly
    
    begin
      calculated_cost = calculate_delivery_cost
      self.cost = calculated_cost
      
      Rails.logger.info "💰 Calculated cost: #{self.cost} for #{delivery_type} delivery"
      
    rescue => e
      Rails.logger.error "Cost calculation failed: #{e.message}"
      # Set minimum cost based on delivery type
      self.cost = case delivery_type
                  when 'fragile' then 200
                  when 'collection' then 250
                  when 'express' then 300
                  else 150
                  end
    end
  end

  def fragile_package_requirements
    return unless fragile?
    
    # Enhanced validation for fragile packages
    if cost && cost < 150
      errors.add(:cost, 'cannot be less than 150 KES for fragile packages due to special handling requirements')
    end
  end

  def collection_package_requirements
    return unless collection?
    
    # Validation for collection packages
    if cost && cost < 200
      errors.add(:cost, 'cannot be less than 200 KES for collection services')
    end
    
    # Collection packages might need additional validations
    # e.g., shop_name, collection_address, etc.
  end

  def update_fragile_metadata
    return unless fragile?
    
    # This method can be used to set additional metadata for fragile packages
    Rails.logger.info "🔧 Updating fragile metadata for package #{code}"
  end

  def generate_qr_code_files
    # Generate QR codes after successful save
    job_options = {
      priority: requires_special_handling? ? 'high' : 'normal',
      delivery_type: delivery_type
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
end