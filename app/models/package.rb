# app/models/package.rb
class Package < ApplicationRecord
  belongs_to :user
  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true
  belongs_to :origin_agent, class_name: 'Agent', optional: true
  belongs_to :destination_agent, class_name: 'Agent', optional: true

  enum delivery_type: { doorstep: 'doorstep', agent: 'agent', mixed: 'mixed' }
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

  # Callbacks
  before_create :generate_package_code_and_sequence
  after_create :generate_qr_code_file

  # Scopes
  scope :by_route, ->(origin_id, destination_id) { 
    where(origin_area_id: origin_id, destination_area_id: destination_id) 
  }
  scope :intra_area, -> { where('origin_area_id = destination_area_id') }
  scope :inter_area, -> { where('origin_area_id != destination_area_id') }

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

  # Instance methods
  def intra_area_shipment?
    origin_area_id == destination_area_id
  end

  def inter_area_shipment?
    !intra_area_shipment?
  end

  def route_description
    if intra_area_shipment?
      "Within #{origin_area&.name}"
    else
      "#{origin_area&.name} → #{destination_area&.name}"
    end
  end

  def display_identifier
    "#{code} (#{route_description})"
  end

  # QR Code methods
  def generate_qr_code(options = {})
    QrCodeGenerator.new(self, options).generate
  end

  def qr_code_base64(options = {})
    QrCodeGenerator.new(self, options).generate_base64
  end

  def qr_code_path(options = {})
    QrCodeGenerator.new(self, options).generate_and_save
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
      'tracking_url' => tracking_url
    )
    
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
        'is_delivered' => delivered? || collected?
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

  # Cost calculation
  def calculate_delivery_cost
    return 0 unless origin_area && destination_area

    price = Price.find_by(
      origin_area_id: origin_area_id,
      destination_area_id: destination_area_id,
      origin_agent_id: origin_agent_id,
      destination_agent_id: destination_agent_id,
      delivery_type: delivery_type
    )

    price&.cost || calculate_default_cost
  end

  def update_cost!
    new_cost = calculate_delivery_cost
    update!(cost: new_cost) if new_cost != cost
  end

  private

  def generate_package_code_and_sequence
    return if code.present? # Don't regenerate if already set
    
    # Generate code using the PackageCodeGenerator service
    self.code = PackageCodeGenerator.new(self).generate
  end

  def generate_qr_code_file
    # Generate and save QR code file asynchronously (optional)
    # You can use background jobs for this in production
    GenerateQrCodeJob.perform_later(self) if defined?(GenerateQrCodeJob)
  rescue => e
    # Log error but don't fail package creation
    Rails.logger.error "Failed to generate QR code for package #{id}: #{e.message}"
  end

  def calculate_default_cost
    # Fallback cost calculation if no specific price found
    if intra_area_shipment?
      case delivery_type
      when 'doorstep' then 150
      when 'agent' then 100
      when 'mixed' then 125
      else 100
      end
    else
      # Inter-area shipping
      base_cost = case delivery_type
                  when 'doorstep' then 300
                  when 'agent' then 200
                  when 'mixed' then 250
                  else 200
                  end
      
      # Add distance factor if you have coordinates
      # base_cost + distance_surcharge
      base_cost
    end
  end
end