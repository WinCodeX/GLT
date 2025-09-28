# app/models/package.rb - Enhanced with ActionCable broadcasting and automatic background job triggering

class Package < ApplicationRecord
  belongs_to :user
  belongs_to :business, optional: true
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
    doorstep: 'doorstep',
    home: 'home',
    office: 'office',
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

  # UPDATED: Enhanced package size enum
  enum package_size: {
    small: 'small',
    medium: 'medium', 
    large: 'large'
  }, _prefix: true

  validates :delivery_type, :state, :cost, presence: true
  validates :code, presence: true, uniqueness: true
  validates :resubmission_count, presence: true, inclusion: { in: 0..2 }
  validates :route_sequence, presence: true, uniqueness: { 
    scope: [:origin_area_id, :destination_area_id],
    message: "Package sequence must be unique for this route"
  }, unless: :location_based_delivery?
  validates :origin_area_id, :destination_area_id, presence: true, unless: :location_based_delivery?
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
  scope :for_business, ->(business) { where(business: business) }
  scope :with_business, -> { where.not(business_id: nil) }
  scope :without_business, -> { where(business_id: nil) }

  # Callbacks
  before_create :generate_package_code_and_sequence, :set_initial_deadlines
  after_create :generate_qr_code_files, :schedule_expiry_management, :create_business_activity
  before_save :populate_business_fields, :update_delivery_metadata, :calculate_cost_if_needed, :update_deadlines_on_state_change

  # ENHANCED: ActionCable broadcasting callbacks for real-time updates
  after_update_commit :broadcast_cart_count_update, if: :saved_change_to_state?
  after_create_commit :broadcast_cart_count_update
  after_destroy_commit :broadcast_cart_count_update
  after_update_commit :broadcast_package_status_update, if: :should_broadcast_package_update?

  # ===========================================
  # ACTIONCABLE BROADCASTING METHODS
  # ===========================================

  # NEW: Broadcast cart count changes to user in real-time
  def broadcast_cart_count_update
    return unless user_id.present?
    
    begin
      # Calculate new cart count (pending_unpaid packages)
      cart_count = Package.where(user_id: user_id, state: 'pending_unpaid').count
      
      # Broadcast to user's cart channel
      ActionCable.server.broadcast(
        "user_cart_#{user_id}",
        {
          type: 'cart_count_update',
          cart_count: cart_count,
          package_id: id,
          package_code: code,
          state_change: saved_change_to_state || [nil, state],
          timestamp: Time.current.iso8601
        }
      )
      
      Rails.logger.info "📡 Cart count update broadcast to user #{user_id}: #{cart_count} items (Package: #{code})"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast cart count update for package #{code}: #{e.message}"
    end
  end

  # NEW: Broadcast package status updates for real-time tracking
  def broadcast_package_status_update
    return unless user_id.present?
    
    begin
      ActionCable.server.broadcast(
        "user_packages_#{user_id}",
        {
          type: 'package_status_update',
          package: {
            id: id,
            code: code,
            state: state,
            state_display: state_display,
            current_location: current_location,
            estimated_delivery: estimated_delivery&.iso8601,
            last_updated: updated_at.iso8601
          },
          timestamp: Time.current.iso8601
        }
      )
      
      Rails.logger.info "📡 Package status update broadcast to user #{user_id} for package #{code}"
    rescue => e
      Rails.logger.error "❌ Failed to broadcast package update for package #{code}: #{e.message}"
    end
  end

  # ===========================================
  # FIXED: BACKGROUND JOB MANAGEMENT
  # ===========================================

  # FIXED: Ensure the recurring expiry management job is running
  def self.ensure_expiry_management_running!
    Rails.logger.info "🔄 Ensuring package expiry management job is running..."
    
    begin
      # Check if there are any packages that need processing
      packages_needing_attention = overdue.count + approaching_deadline.count + rejected_for_deletion.count
      
      if packages_needing_attention > 0
        Rails.logger.info "📦 Found #{packages_needing_attention} packages needing attention - starting expiry management job"
        
        # Start the recurring job immediately
        PackageExpiryManagementJob.perform_later
        
        Rails.logger.info "✅ Package expiry management job started"
      else
        Rails.logger.info "✅ No packages need immediate attention, but job is scheduled for monitoring"
        # Still start the job for future monitoring
        PackageExpiryManagementJob.perform_later
      end
      
    rescue => e
      Rails.logger.error "❌ Failed to start expiry management job: #{e.message}"
      Rails.logger.error "🔍 Error details: #{e.class.name} - #{e.backtrace.first(3).join(', ')}"
    end
  end

  # FIXED: Process any immediately overdue packages
  def self.process_immediate_overdue_packages!
    Rails.logger.info "🚨 Processing immediately overdue packages..."
    
    begin
      rejected_count = 0
      deleted_count = 0
      
      # Process overdue packages
      overdue.where(state: ['pending_unpaid', 'pending']).find_each do |package|
        reason = case package.state
                when 'pending_unpaid'
                  "Payment not received within deadline"
                when 'pending'
                  "Package not submitted for delivery within deadline"
                else
                  "Package expired"
                end
        
        if package.reject_package!(reason: reason, auto_rejected: true)
          Rails.logger.info "⚠️ Auto-rejected overdue package: #{package.code}"
          rejected_count += 1
        end
      end
      
      # Process packages ready for deletion
      rejected_for_deletion.find_each do |package|
        begin
          Rails.logger.info "🗑️ Deleting permanently rejected package: #{package.code}"
          package.destroy!
          deleted_count += 1
        rescue => e
          Rails.logger.error "❌ Failed to delete package #{package.code}: #{e.message}"
        end
      end
      
      Rails.logger.info "✅ Immediate processing complete: #{rejected_count} rejected, #{deleted_count} deleted"
      
      { rejected: rejected_count, deleted: deleted_count }
      
    rescue => e
      Rails.logger.error "❌ Failed to process immediate overdue packages: #{e.message}"
      { rejected: 0, deleted: 0, error: e.message }
    end
  end

  # ===========================================
  # RESUBMISSION LOGIC
  # ===========================================

  def can_be_resubmitted?
    rejected? && resubmission_count < 2 && !final_deadline_passed?
  end

  def resubmit!(reason: nil)
    return false unless can_be_resubmitted?

    transaction do
      self.original_state ||= 'pending' if state == 'rejected'
      self.resubmission_count += 1
      self.resubmitted_at = Time.current
      
      new_expiry_time = calculate_resubmission_deadline
      self.expiry_deadline = new_expiry_time
      
      target_state = original_state || 'pending'
      self.state = target_state
      
      self.rejected_at = nil
      self.auto_rejected = false
      
      update_resubmission_metadata(reason)
      save!
      
      if defined?(Notification)
        Notification.create_resubmission_success(
          package: self,
          new_deadline: new_expiry_time
        )
      end
      
      # FIXED: Schedule individual expiry check for this package
      schedule_individual_expiry_check
      
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
      self.original_state = state unless rejected?
      self.state = 'rejected'
      self.rejection_reason = reason
      self.rejected_at = Time.current
      self.auto_rejected = auto_rejected
      self.final_deadline = 1.week.from_now
      
      save!
      
      if defined?(Notification)
        Notification.create_package_rejection(
          package: self,
          reason: reason,
          auto_rejected: auto_rejected
        )
      end
      
      # FIXED: Schedule deletion job for auto-rejected packages
      if auto_rejected && defined?(DeleteRejectedPackageJob)
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
    
    pending_unpaid_expired.find_each do |package|
      if package.reject_package!(
        reason: "Payment not received within 7 days",
        auto_rejected: true
      )
        rejected_count += 1
      end
    end
    
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
      
      if defined?(Notification)
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
    end
    
    Rails.logger.info "Sent expiry warnings for #{warned_count} packages"
    warned_count
  end

  # Class methods
  def self.find_by_code_or_id(identifier)
    identifier = identifier.to_s.strip
    package = find_by(code: identifier)
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

  def requires_package_size?
    ['home', 'office', 'doorstep'].include?(delivery_type)
  end

  def requires_special_instructions?
    package_size_large? && ['home', 'office', 'doorstep'].include?(delivery_type)
  end

  def large_package?
    package_size_large?
  end

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

  def has_business?
    business_id.present?
  end

  def business_name_display
    business_name.presence || business&.name || 'No Business'
  end

  def business_phone_display
    business_phone.presence || business&.phone_number || 'No Phone'
  end

  def intra_area_shipment?
    return false if location_based_delivery?
    origin_area_id == destination_area_id
  end

  def route_description
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
        module_size: 14,
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
        module_size: 7,
        border_size: 14,
        corner_radius: 4
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
    fragile_delivery? || large_package? || (cost > 1000)
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
    
    if has_business?
      instructions << "Business: #{business_name_display}"
    end
    
    instructions.join(' ')
  end

  def as_json(options = {})
    result = super(options).except('route_sequence')
    
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
      'has_business' => has_business?,
      'business_name_display' => business_name_display,
      'business_phone_display' => business_phone_display,
      'can_be_resubmitted' => can_be_resubmitted?,
      'resubmission_count' => resubmission_count,
      'remaining_resubmissions' => [0, 2 - resubmission_count].max,
      'hours_until_expiry' => hours_until_expiry,
      'resubmission_limit_text' => resubmission_deadline_text,
      'final_deadline_passed' => final_deadline_passed?
    )
    
    if options[:include_business] && business
      result.merge!(
        'business' => {
          'id' => business.id,
          'name' => business.name,
          'phone_number' => business.phone_number,
          'logo_url' => business.logo_url
        }
      )
    end
    
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

    if expiry_deadline.present?
      result.merge!(
        'expiry_deadline' => expiry_deadline.iso8601,
        'time_until_expiry_hours' => hours_until_expiry
      )
    end
    
    result
  end

  private

  # NEW: Helper method to determine if package update should be broadcast
  def should_broadcast_package_update?
    saved_change_to_state? || 
    saved_change_to_current_location? || 
    saved_change_to_estimated_delivery?
  end

  def populate_business_fields
    if business_id.present? && business
      if business_name.blank?
        self.business_name = business.name
        Rails.logger.debug "Auto-populated business_name: #{business.name} for package #{id || 'new'}"
      end
      
      if business_phone.blank?
        self.business_phone = business.phone_number
        Rails.logger.debug "Auto-populated business_phone: #{business.phone_number} for package #{id || 'new'}"
      end
    elsif business_id.blank?
      self.business_name = nil
      self.business_phone = nil
      Rails.logger.debug "Cleared business fields for package #{id || 'new'}"
    end
  rescue => e
    Rails.logger.error "Failed to populate business fields for package #{id || 'new'}: #{e.message}"
  end

  def create_business_activity
    return unless business_id.present? && business

    begin
      if defined?(BusinessActivity)
        activity_metadata = {
          package_code: code,
          delivery_type: delivery_type,
          cost: cost,
          destination_area: destination_area&.name,
          recipient_name: receiver_name,
          package_size: package_size,
          created_by_staff: user != business.owner
        }

        if location_based_delivery? && pickup_location.present?
          activity_metadata[:pickup_location] = pickup_location
        end

        if delivery_location.present?
          activity_metadata[:delivery_location] = delivery_location
        end

        BusinessActivity.create_package_activity(
          business: business,
          user: user,
          package: self,
          activity_type: 'package_created',
          metadata: activity_metadata
        )
        
        Rails.logger.info "Created enhanced business activity for package #{code} and business #{business.name} with recipient: #{receiver_name}"
      end
    rescue => e
      Rails.logger.error "Failed to create business activity for package #{code}: #{e.message}"
    end
  end

  def set_initial_deadlines
    case state
    when 'pending_unpaid', 'pending'
      self.expiry_deadline ||= 7.days.from_now
    end
  end

  # FIXED: Enhanced expiry management scheduling
  def schedule_expiry_management
    begin
      # Always ensure the recurring management job is running
      Rails.logger.info "📅 Scheduling expiry management for new package #{code}"
      
      # Check if we need to process any overdue packages immediately
      Package.delay(run_at: 1.minute.from_now).process_immediate_overdue_packages!
      
      # Ensure the recurring job is running
      Package.delay(run_at: 2.minutes.from_now).ensure_expiry_management_running!
      
      # Schedule individual package check if this package has a deadline
      schedule_individual_expiry_check
      
    rescue => e
      Rails.logger.error "❌ Failed to schedule expiry management for package #{code}: #{e.message}"
    end
  end

  # FIXED: Individual package expiry checking
  def schedule_individual_expiry_check
    return unless expiry_deadline.present?
    
    begin
      # Schedule warning check (6 hours before expiry)
      warning_time = expiry_deadline - 6.hours
      
      if warning_time > Time.current && defined?(SchedulePackageExpiryJob)
        SchedulePackageExpiryJob.set(wait_until: warning_time).perform_later(id)
        Rails.logger.info "📅 Scheduled warning check for package #{code} at #{warning_time}"
      end
      
      # Schedule final check at expiry time
      if expiry_deadline > Time.current && defined?(SchedulePackageExpiryJob)
        SchedulePackageExpiryJob.set(wait_until: expiry_deadline).perform_later(id)
        Rails.logger.info "📅 Scheduled final check for package #{code} at #{expiry_deadline}"
      end
      
    rescue => e
      Rails.logger.error "❌ Failed to schedule individual expiry check for package #{code}: #{e.message}"
    end
  end

  def update_deadlines_on_state_change
    if state_changed? && !rejected?
      if state.in?(['delivered', 'collected'])
        self.expiry_deadline = nil
        self.final_deadline = nil
      end
    end
  end

  def calculate_resubmission_deadline
    case resubmission_count
    when 1
      3.5.days.from_now
    when 2
      1.day.from_now
    else
      7.days.from_now
    end
  end

  def update_resubmission_metadata(reason)
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

  def generate_package_code_and_sequence
    return if code.present?
    
    generator_options = {}
    generator_options[:fragile] = true if fragile_delivery?
    generator_options[:collection] = true if collection_delivery?
    generator_options[:large] = true if large_package?
    generator_options[:office] = true if office_delivery?
    generator_options[:business] = business if business
    
    if defined?(PackageCodeGenerator)
      self.code = PackageCodeGenerator.new(self, generator_options).generate
    else
      self.code = "PKG-#{SecureRandom.hex(4).upcase}-#{Time.current.strftime('%Y%m%d')}"
    end
    
    unless location_based_delivery?
      self.route_sequence = self.class.next_sequence_for_route(origin_area_id, destination_area_id)
    else
      self.route_sequence = self.class.where(delivery_type: delivery_type).maximum(:route_sequence).to_i + 1
    end
  end

  def generate_qr_code_files
    job_options = {}
    job_options[:priority] = 'high' if fragile_delivery? || large_package?
    job_options[:fragile] = true if fragile_delivery?
    job_options[:collection] = true if collection_delivery?
    job_options[:large] = true if large_package?
    job_options[:business] = business if business
    
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

  def calculate_default_cost
    case delivery_type
    when 'fragile'
      base = intra_area_shipment? ? 300 : 500
      base + (large_package? ? 100 : 0)
    when 'collection'
      base = 350
      base + (large_package? ? 75 : 0)
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
    else
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
    
    if cost && cost < 100
      errors.add(:cost, 'cannot be less than 100 KES for fragile packages due to special handling requirements')
    end
    
    if pickup_location.blank?
      errors.add(:pickup_location, 'is required for fragile deliveries')
    end
  end

  def large_package_requirements
    return unless large_package?
    
    if home_delivery? && special_instructions.blank?
      errors.add(:special_instructions, 'are required for large packages')
    end
    
    if office_delivery?
      errors.add(:delivery_type, 'Office delivery not recommended for large packages. Consider home delivery.')
    end
  end
end