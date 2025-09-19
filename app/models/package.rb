# app/models/package.rb - Enhanced with notification system and automatic rejection logic

class Package < ApplicationRecord
  belongs_to :user
  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true
  belongs_to :origin_agent, class_name: 'Agent', optional: true
  belongs_to :destination_agent, class_name: 'Agent', optional: true

  # Enhanced tracking associations
  has_many :tracking_events, class_name: 'PackageTrackingEvent', dependent: :destroy
  has_many :print_logs, class_name: 'PackagePrintLog', dependent: :destroy
  has_many :notifications, dependent: :destroy

  # UPDATED: Enhanced delivery types to include home and office variants
  enum delivery_type: { 
    doorstep: 'doorstep',        # Legacy - maps to home delivery
    home: 'home',                # NEW: Direct home delivery
    office: 'office',            # NEW: Deliver to office for collection
    agent: 'agent',              # Agent-to-agent delivery
    fragile: 'fragile',          # Fragile items with special handling
    collection: 'collection'     # Collection service
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

  # UPDATED: Enhanced package size enum
  enum package_size: {
    small: 'small',
    medium: 'medium', 
    large: 'large'
  }, _prefix: true

  validates :delivery_type, :state, :cost, presence: true
  validates :code, presence: true, uniqueness: true
  validates :resubmission_count, presence: true, inclusion: { in: 0..2 }
  
  # FIXED: Conditional validation - only for agent-based deliveries
  validates :route_sequence, presence: true, uniqueness: { 
    scope: [:origin_area_id, :destination_area_id],
    message: "Package sequence must be unique for this route"
  }, unless: :location_based_delivery?

  # FIXED: Conditional area validation - only for agent-based deliveries  
  validates :origin_area_id, :destination_area_id, presence: true, unless: :location_based_delivery?

  # UPDATED: Package size validation for home/office deliveries
  validates :special_instructions, presence: true, if: :requires_special_instructions?

  # Additional validation for fragile packages
  validate :fragile_package_requirements, if: :fragile?
  validate :large_package_requirements, if: :large_package?

  # Scopes for automatic processing
  scope :pending_unpaid_expired, -> { 
    where(state: 'pending_unpaid')
    .where('created_at <= ?', 1.week.ago)
    .where(auto_rejected: false)
  }

  scope :pending_expired, -> { 
    where(state: 'pending')
    .where('created_at <= ?', 1.week.ago)
    .where(auto_rejected: false)
  }

  scope :rejected_for_deletion, -> { 
    where(state: 'rejected', auto_rejected: true)
    .where('rejected_at <= ?', 1.week.ago)
  }

  scope :approaching_deadline, -> {
    where.not(expiry_deadline: nil)
    .where(expiry_deadline: 2.hours.from_now..6.hours.from_now)
    .where.not(state: ['rejected', 'delivered', 'collected'])
  }

  scope :overdue, -> {
    where('expiry_deadline <= ?', Time.current)
    .where.not(state: ['rejected', 'delivered', 'collected'])
  }

  # Enhanced scopes
  scope :by_route, ->(origin_id, destination_id) { 
    where(origin_area_id: origin_id, destination_area_id: destination_id) 
  }
  scope :intra_area, -> { where('origin_area_id = destination_area_id') }
  scope :inter_area, -> { where('origin_area_id != destination_area_id') }
  scope :fragile_packages, -> { where(delivery_type: 'fragile') }
  scope :collection_packages, -> { where(delivery_type: 'collection') }
  scope :home_deliveries, -> { where(delivery_type: ['home', 'doorstep']) }
  scope :office_deliveries, -> { where(delivery_type: 'office') }
  scope :standard_packages, -> { where(delivery_type: ['doorstep', 'home', 'office', 'agent']) }
  scope :location_based_packages, -> { where(delivery_type: ['fragile', 'collection']) }
  scope :requiring_special_handling, -> { where(delivery_type: ['fragile', 'collection']).or(where(package_size: 'large')) }

  # Callbacks
  before_create :generate_package_code_and_sequence, :set_initial_deadlines
  after_create :generate_qr_code_files, :schedule_initial_expiry_job
  before_save :update_delivery_metadata, :calculate_cost_if_needed, :update_deadlines_on_state_change

  # ===========================================
  # RESUBMISSION LOGIC
  # ===========================================

  def can_be_resubmitted?
    rejected? && resubmission_count < 2 && !final_deadline_passed?
  end

  def resubmit!(reason: nil)
    return false unless can_be_resubmitted?

    transaction do
      # Store previous state if not already stored
      self.original_state ||= 'pending' if state == 'rejected'
      
      # Increment resubmission count
      self.resubmission_count += 1
      self.resubmitted_at = Time.current
      
      # Calculate new deadline based on resubmission count
      new_expiry_time = calculate_resubmission_deadline
      self.expiry_deadline = new_expiry_time
      
      # Restore to original state
      target_state = original_state || 'pending'
      self.state = target_state
      
      # Clear rejection data but keep history
      self.rejected_at = nil
      self.auto_rejected = false
      
      # Update metadata
      update_resubmission_metadata(reason)
      
      save!
      
      # Create success notification
      Notification.create_resubmission_success(
        package: self,
        new_deadline: new_expiry_time
      )
      
      # FIXED: Schedule new expiry check
      SchedulePackageExpiryJob.set(wait_until: new_expiry_time - 2.hours).perform_later(self.id)
      
      Rails.logger.info "Package #{code} resubmitted (#{resubmission_count}/2) - New deadline: #{new_expiry_time}"
      
      true
    end
  rescue => e
    Rails.logger.error "Failed to resubmit package #{code}: #{e.message}"
    false
  end

  def reject_package!(reason:, auto_rejected: false)
    return false if rejected?

    transaction do
      # Store original state for potential resubmission
      self.original_state = state unless rejected?
      
      # Update rejection fields
      self.state = 'rejected'
      self.rejection_reason = reason
      self.rejected_at = Time.current
      self.auto_rejected = auto_rejected
      
      # Set final deadline for automatic deletion (1 week for manual review)
      self.final_deadline = 1.week.from_now
      
      save!
      
      # Create rejection notification
      Notification.create_package_rejection(
        package: self,
        reason: reason,
        auto_rejected: auto_rejected
      )
      
      # FIXED: Schedule automatic deletion if auto-rejected
      if auto_rejected
        DeleteRejectedPackageJob.set(wait_until: final_deadline).perform_later(self.id)
      end
      
      Rails.logger.info "Package #{code} rejected: #{reason} (auto: #{auto_rejected})"
      
      true
    end
  rescue => e
    Rails.logger.error "Failed to reject package #{code}: #{e.message}"
    false
  end

  def time_until_expiry
    return nil unless expiry_deadline
    return 0 if expiry_deadline <= Time.current
    
    expiry_deadline - Time.current
  end

  def hours_until_expiry
    return nil unless time_until_expiry
    (time_until_expiry / 1.hour).round(1)
  end

  def final_deadline_passed?
    final_deadline.present? && final_deadline <= Time.current
  end

  def resubmission_deadline_text
    case resubmission_count
    when 0
      "7 days"
    when 1
      "3.5 days"
    when 2
      "1 day"
    else
      "No resubmissions remaining"
    end
  end

  # ===========================================
  # CLASS METHODS FOR BATCH PROCESSING
  # ===========================================

  def self.auto_reject_expired_packages!
    rejected_count = 0
    
    # Process pending_unpaid packages
    pending_unpaid_expired.find_each do |package|
      if package.reject_package!(
        reason: "Payment not received within 7 days",
        auto_rejected: true
      )
        rejected_count += 1
      end
    end
    
    # Process pending packages
    pending_expired.find_each do |package|
      if package.reject_package!(
        reason: "Package not submitted for delivery within 7 days",
        auto_rejected: true
      )
        rejected_count += 1
      end
    end
    
    Rails.logger.info "Auto-rejected #{rejected_count} expired packages"
    rejected_count
  end

  def self.delete_expired_rejected_packages!
    deleted_count = 0
    
    rejected_for_deletion.find_each do |package|
      begin
        Rails.logger.info "Deleting permanently rejected package: #{package.code}"
        package.destroy!
        deleted_count += 1
      rescue => e
        Rails.logger.error "Failed to delete package #{package.code}: #{e.message}"
      end
    end
    
    Rails.logger.info "Deleted #{deleted_count} permanently rejected packages"
    deleted_count
  end

  def self.send_expiry_warnings!
    warned_count = 0
    
    approaching_deadline.find_each do |package|
      hours_remaining = package.hours_until_expiry
      next unless hours_remaining && hours_remaining > 0
      
      # Only send warning once when between 2-6 hours remain
      last_warning = package.notifications
        .where(notification_type: 'final_warning')
        .where('created_at >= ?', 8.hours.ago)
        .exists?
      
      unless last_warning
        Notification.create_expiry_warning(
          package: package,
          hours_remaining: hours_remaining.round(1)
        )
        warned_count += 1
      end
    end
    
    Rails.logger.info "Sent expiry warnings for #{warned_count} packages"
    warned_count
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

  def self.fragile_packages_in_transit
    fragile_packages.where(state: ['submitted', 'in_transit'])
  end

  def self.packages_requiring_special_attention
    requiring_special_handling.where(state: ['submitted', 'in_transit'])
  end

  # UPDATED: New method to identify location-based deliveries
  def location_based_delivery?
    ['fragile', 'collection'].include?(delivery_type)
  end

  # UPDATED: Check if package requires package size
  def requires_package_size?
    ['home', 'office', 'doorstep'].include?(delivery_type)
  end

  # UPDATED: Check if special instructions are required
  def requires_special_instructions?
    package_size_large? && ['home', 'office', 'doorstep'].include?(delivery_type)
  end

  # UPDATED: Check if this is a large package
  def large_package?
    package_size_large?
  end

  # UPDATED: Enhanced delivery type checking
  def home_delivery?
    ['home', 'doorstep'].include?(delivery_type)
  end

  def office_delivery?
    delivery_type == 'office'
  end

  def agent_delivery?
    delivery_type == 'agent'
  end

  def collection_delivery?
    delivery_type == 'collection'
  end

  def fragile_delivery?
    delivery_type == 'fragile'
  end

  # Instance methods
  def intra_area_shipment?
    return false if location_based_delivery?
    origin_area_id == destination_area_id
  end

  def route_description
    # UPDATED: Handle route description for all delivery types
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

  # UPDATED: Enhanced QR options based on delivery type and package size
  def organic_qr_options
    base_options = {
      module_size: 12,
      border_size: 24,
      corner_radius: 8,
      center_logo: true,
      gradient: true,
      logo_size: 40
    }
    
    if fragile_delivery?
      base_options.merge({
        fragile_indicator: true,
        priority_handling: true,
        module_size: 14, # Larger for fragile visibility
        border_size: 28,
        corner_radius: 6
      })
    elsif collection_delivery?
      base_options.merge({
        collection_indicator: true,
        module_size: 13,
        border_size: 26
      })
    elsif large_package?
      base_options.merge({
        large_package_indicator: true,
        module_size: 13,
        border_size: 26,
        corner_radius: 6
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
    
    if fragile_delivery?
      base_options.merge({
        fragile_indicator: true,
        priority_handling: true,
        module_size: 7, # Slightly larger for fragile visibility
        border_size: 14,
        corner_radius: 4 # More organic rounding even for thermal
      })
    elsif collection_delivery?
      base_options.merge({
        collection_indicator: true,
        module_size: 6,
        border_size: 13
      })
    elsif large_package?
      base_options.merge({
        large_package_indicator: true,
        module_size: 7,
        border_size: 14
      })
    else
      base_options
    end
  end

  # UPDATED: Enhanced JSON serialization with new delivery types and resubmission info
  def as_json(options = {})
    result = super(options).except('route_sequence') # Hide internal sequence from API
    
    # Always include these computed fields
    result.merge!(
      'tracking_code' => code,
      'route_description' => route_description,
      'is_intra_area' => intra_area_shipment?,
      'tracking_url' => tracking_url,
      'is_fragile' => fragile_delivery?,
      'is_collection' => collection_delivery?,
      'is_home_delivery' => home_delivery?,
      'is_office_delivery' => office_delivery?,
      'is_location_based' => location_based_delivery?,
      'requires_special_handling' => requires_special_handling?,
      'priority_level' => priority_level,
      'delivery_type_display' => delivery_type_display,
      'package_size_display' => package_size_display,
      
      # Resubmission and expiry information
      'can_be_resubmitted' => can_be_resubmitted?,
      'resubmission_count' => resubmission_count,
      'remaining_resubmissions' => [0, 2 - resubmission_count].max,
      'hours_until_expiry' => hours_until_expiry,
      'resubmission_limit_text' => resubmission_deadline_text,
      'final_deadline_passed' => final_deadline_passed?
    )
    
    # Include delivery-specific information
    if fragile_delivery?
      result.merge!(
        'handling_instructions' => handling_instructions,
        'fragile_warning' => 'This package requires special handling due to fragile contents'
      )
    end

    if collection_delivery?
      result.merge!(
        'collection_instructions' => 'Package will be collected from specified pickup location',
        'collection_type' => 'Location-based collection service'
      )
    end

    if large_package?
      result.merge!(
        'size_warning' => 'Large package - special handling required',
        'special_instructions' => special_instructions
      )
    end

    # Include rejection information if rejected
    if rejected?
      result.merge!(
        'rejection_info' => {
          'reason' => rejection_reason,
          'rejected_at' => rejected_at&.iso8601,
          'auto_rejected' => auto_rejected?,
          'original_state' => original_state
        }
      )
    end

    # Include expiry information if applicable
    if expiry_deadline.present?
      result.merge!(
        'expiry_deadline' => expiry_deadline.iso8601,
        'time_until_expiry_hours' => hours_until_expiry
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
    !fragile_delivery? && !large_package?
  end

  def needs_priority_handling?
    fragile_delivery? || large_package? || (cost > 1000) # High value, fragile, or large packages get priority
  end

  def requires_special_handling?
    fragile_delivery? || collection_delivery? || large_package?
  end

  def priority_level
    case delivery_type
    when 'fragile'
      'high'
    when 'collection'
      'medium'
    else
      large_package? ? 'medium' : 'standard'
    end
  end

  # UPDATED: Enhanced delivery type display
  def delivery_type_display
    case delivery_type
    when 'doorstep', 'home'
      'Home Delivery'
    when 'office'
      'Office Delivery'
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

  # UPDATED: Package size display
  def package_size_display
    case package_size
    when 'small'
      'Small Package'
    when 'medium'
      'Medium Package'  
    when 'large'
      'Large Package'
    else
      'Standard Size'
    end
  end

  # UPDATED: Enhanced handling instructions
  def handling_instructions
    instructions = []
    
    case delivery_type
    when 'fragile'
      instructions << 'Handle with extreme care. This package contains fragile items.'
    when 'collection'
      instructions << 'Collection service - pick up from specified location.'
    when 'home', 'doorstep'
      instructions << 'Deliver directly to recipient address.'
    when 'office'
      instructions << 'Deliver to office for recipient collection.'
    else
      instructions << 'Standard handling procedures apply.'
    end
    
    if large_package?
      instructions << 'Large package - requires special handling and may need additional manpower.'
    end
    
    if special_instructions.present?
      instructions << "Special instructions: #{special_instructions}"
    end
    
    instructions.join(' ')
  end

  private

  def set_initial_deadlines
    # Set initial expiry deadline based on state
    case state
    when 'pending_unpaid', 'pending'
      self.expiry_deadline ||= 7.days.from_now
    end
  end

  def schedule_initial_expiry_job
    return unless expiry_deadline.present?
    
    # Schedule warning check (6 hours before expiry)
    warning_time = expiry_deadline - 6.hours
    if warning_time > Time.current
      SchedulePackageExpiryJob.set(wait_until: warning_time).perform_later(id)
    else
      # If too close to deadline, schedule final check
      SchedulePackageExpiryJob.set(wait_until: expiry_deadline).perform_later(id)
    end
  end

  def update_deadlines_on_state_change
    if state_changed? && !rejected?
      # Clear expiry deadline for final states
      if state.in?(['delivered', 'collected'])
        self.expiry_deadline = nil
        self.final_deadline = nil
      end
    end
  end

  def calculate_resubmission_deadline
    case resubmission_count
    when 1
      3.5.days.from_now  # 7 days / 2
    when 2
      1.day.from_now     # Final attempt
    else
      7.days.from_now    # Should not happen, but fallback
    end
  end

  def update_resubmission_metadata(reason)
    # Add to metadata for tracking
    self.metadata ||= {}
    self.metadata['resubmission_history'] ||= []
    self.metadata['resubmission_history'] << {
      attempt: resubmission_count,
      resubmitted_at: Time.current.iso8601,
      reason: reason,
      previous_deadline: expiry_deadline&.iso8601,
      new_deadline: calculate_resubmission_deadline.iso8601
    }
  end

  # UPDATED: Enhanced code and sequence generation
  def generate_package_code_and_sequence
    return if code.present?
    
    # Generate code using the PackageCodeGenerator service
    generator_options = {}
    generator_options[:fragile] = true if fragile_delivery?
    generator_options[:collection] = true if collection_delivery?
    generator_options[:large] = true if large_package?
    generator_options[:office] = true if office_delivery?
    
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
    job_options[:priority] = 'high' if fragile_delivery? || large_package?
    job_options[:fragile] = true if fragile_delivery?
    job_options[:collection] = true if collection_delivery?
    job_options[:large] = true if large_package?
    
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

  # UPDATED: Enhanced cost calculation with all delivery types
  def calculate_default_cost
    case delivery_type
    when 'fragile'
      base = intra_area_shipment? ? 300 : 500
      base + (large_package? ? 100 : 0) # Additional for large fragile items
    when 'collection'
      base = 350
      base + (large_package? ? 75 : 0) # Additional for large collections
    when 'home', 'doorstep'
      base = intra_area_shipment? ? 250 : 380
      base * package_size_multiplier
    when 'office'
      base = intra_area_shipment? ? 180 : 280
      base * package_size_multiplier
    when 'agent'
      intra_area_shipment? ? 120 : 200
    else
      200
    end
  end

  def package_size_multiplier
    case package_size
    when 'small'
      0.8
    when 'large'
      1.4
    else # medium
      1.0
    end
  end

  def calculate_cost_if_needed
    if cost.nil? || cost.zero?
      self.cost = calculate_default_cost
    end
  end

  def update_delivery_metadata
    # Update any delivery-specific metadata
    case delivery_type
    when 'fragile'
      # Set fragile-specific metadata
    when 'collection'
      # Set collection-specific metadata
    when 'home', 'office'
      # Set home/office delivery metadata
    end
  end

  def fragile_package_requirements
    return unless fragile_delivery?
    
    # Add specific validations for fragile packages
    if cost && cost < 100
      errors.add(:cost, 'cannot be less than 100 KES for fragile packages due to special handling requirements')
    end
    
    if pickup_location.blank?
      errors.add(:pickup_location, 'is required for fragile deliveries')
    end
  end

  def large_package_requirements
    return unless large_package?
    
    # Validate large package requirements
    if home_delivery? && special_instructions.blank?
      errors.add(:special_instructions, 'are required for large packages')
    end
    
    if office_delivery?
      errors.add(:delivery_type, 'Office delivery not recommended for large packages. Consider home delivery.')
    end
  end
end