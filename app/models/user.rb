# app/models/user.rb - Integrated with Rolify and scanning functionality
class User < ApplicationRecord
  # Include default devise modules + JWT
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :jwt_authenticatable, jwt_revocation_strategy: Devise::JWT::RevocationStrategies::Null

  # ActiveStorage for avatar
  has_one_attached :avatar

  # Business relationships (existing)
  has_many :owned_businesses, class_name: "Business", foreign_key: "owner_id"
  has_many :user_businesses
  has_many :businesses, through: :user_businesses

  # Package delivery system relationships (existing + new scanning)
  has_many :packages, dependent: :destroy
  
  # NEW: Scanning-related associations
  has_many :agents, dependent: :destroy
  has_many :riders, dependent: :destroy
  has_many :warehouse_staff, dependent: :destroy
  has_many :package_tracking_events, dependent: :destroy
  has_many :package_print_logs, dependent: :destroy

  # Messaging system relationships (existing)
  has_many :conversation_participants, dependent: :destroy
  has_many :conversations, through: :conversation_participants
  has_many :messages, dependent: :destroy

  # Rolify for roles (existing)
  rolify

  # Validations
  validates :email, presence: true, uniqueness: true
  validates :first_name, presence: true, length: { minimum: 2, maximum: 100 }
  validates :phone_number, format: { with: /\A\+?[0-9\s\-\(\)]+\z/, message: "Invalid phone format" }, allow_blank: true

  # Callbacks
  after_create :assign_default_role
  before_validation :normalize_phone

  # Scopes (existing + new)
  scope :active, -> { where.not(last_seen_at: nil).where('last_seen_at > ?', 30.days.ago) }
  scope :inactive, -> { where(last_seen_at: nil).or(where('last_seen_at <= ?', 30.days.ago)) }
  scope :with_scanning_activity, -> { joins(:package_tracking_events).distinct }
  scope :recent_scanners, -> { joins(:package_tracking_events).where(package_tracking_events: { created_at: 1.week.ago.. }).distinct }

  # EXISTING: Messaging system methods
  def mark_online!
    update!(online: true, last_seen_at: Time.current)
  end

  def mark_offline!
    update!(online: false, last_seen_at: Time.current)
  end

  def support_conversations
    conversations.where(conversation_type: 'support_ticket')
  end

  def direct_conversations
    conversations.where(conversation_type: 'direct_message')
  end

  def active_support_tickets_count
    conversation_participants.joins(:conversation)
                            .where(conversations: { conversation_type: 'support_ticket' })
                            .where(role: 'agent')
                            .where("conversations.metadata->>'status' IN (?)", ['assigned', 'in_progress', 'waiting_customer'])
                            .count
  end

  def full_name
    if first_name.present? || last_name.present?
      "#{first_name} #{last_name}".strip
    else
      email.split('@').first
    end
  end

  def display_name
    full_name.present? ? full_name : email.split('@').first
  end

  def initials
    full_name.split.map(&:first).join.upcase
  end

  # Check if user is active (based on recent activity)
  def active?
    last_seen_at.present? && last_seen_at > 30.days.ago
  end

  # EXISTING: Role compatibility methods using Rolify
  def support_agent?
    has_role?(:support)
  end

  def client?
    has_role?(:client)
  end

  def admin?
    has_role?(:admin)
  end

  # NEW: Package delivery role methods using Rolify
  def agent?
    has_role?(:agent)
  end

  def rider?
    has_role?(:rider)
  end

  def warehouse?
    has_role?(:warehouse)
  end

  def staff?
    has_role?(:agent) || has_role?(:rider) || has_role?(:warehouse) || has_role?(:admin)
  end

  # For messaging system compatibility
  def customer?
    client? # Maps client role to customer for support system
  end

  # NEW: Package scanning permission methods
  def can_scan_packages?
    staff?
  end

  def can_print_labels?
    has_role?(:agent) || has_role?(:warehouse) || has_role?(:admin)
  end

  def can_manage_packages?
    has_role?(:warehouse) || has_role?(:admin)
  end

  def can_view_all_packages?
    has_role?(:warehouse) || has_role?(:admin)
  end

  # NEW: Role-specific helper methods
  def primary_role
    return 'admin' if has_role?(:admin)
    return 'warehouse' if has_role?(:warehouse)
    return 'rider' if has_role?(:rider)
    return 'agent' if has_role?(:agent)
    return 'support' if has_role?(:support)
    return 'client' if has_role?(:client)
    'client' # default
  end

  def role_display_name
    case primary_role
    when 'client' then 'Customer'
    when 'agent' then 'Agent'
    when 'rider' then 'Delivery Rider'
    when 'warehouse' then 'Warehouse Staff'
    when 'admin' then 'Administrator'
    when 'support' then 'Support Agent'
    else primary_role.humanize
    end
  end

  def role_description
    case primary_role
    when 'client' then 'Creates and tracks packages'
    when 'agent' then 'Collects packages and prints labels'
    when 'rider' then 'Picks up and delivers packages'
    when 'warehouse' then 'Processes and sorts packages'
    when 'admin' then 'Full system administration'
    when 'support' then 'Provides customer support'
    else 'System user'
    end
  end

  def available_actions
    actions = []
    actions << 'confirm_receipt' if has_role?(:client)
    actions << 'print' if has_role?(:agent)
    actions += ['collect', 'deliver'] if has_role?(:rider)
    actions += ['collect', 'process', 'print'] if has_role?(:warehouse)
    actions += ['collect', 'deliver', 'print', 'process', 'confirm_receipt'] if has_role?(:admin)
    actions.uniq
  end

  # NEW: Area/Location access methods
  def accessible_areas
    case primary_role
    when 'agent'
      agents.joins(:area).pluck('areas.id').uniq
    when 'rider'
      riders.joins(:area).pluck('areas.id').uniq
    when 'warehouse'
      warehouse_staff.joins(:location).joins('locations.areas').pluck('areas.id').uniq
    when 'admin'
      Area.pluck(:id)
    else
      []
    end
  end

  def accessible_locations
    case primary_role
    when 'agent'
      agents.joins(area: :location).pluck('locations.id').uniq
    when 'rider'
      riders.joins(area: :location).pluck('locations.id').uniq
    when 'warehouse'
      warehouse_staff.pluck(:location_id).uniq
    when 'admin'
      Location.pluck(:id)
    else
      []
    end
  end

  def operates_in_area?(area_id)
    accessible_areas.include?(area_id)
  end

  def operates_in_location?(location_id)
    accessible_locations.include?(location_id)
  end

  # NEW: Package access methods
  def accessible_packages
    case primary_role
    when 'client'
      packages
    when 'agent'
      area_ids = accessible_areas
      Package.where(origin_area_id: area_ids).or(Package.where(destination_area_id: area_ids))
    when 'rider'
      area_ids = accessible_areas
      Package.where(origin_area_id: area_ids).or(Package.where(destination_area_id: area_ids))
    when 'warehouse'
      location_ids = accessible_locations
      area_ids = Area.where(location_id: location_ids).pluck(:id)
      Package.where(origin_area_id: area_ids).or(Package.where(destination_area_id: area_ids))
    when 'admin'
      Package.all
    else
      Package.none
    end
  end

  def can_access_package?(package)
    case primary_role
    when 'client'
      package.user_id == id
    when 'agent'
      operates_in_area?(package.origin_area_id) || operates_in_area?(package.destination_area_id)
    when 'rider'
      operates_in_area?(package.origin_area_id) || operates_in_area?(package.destination_area_id)
    when 'warehouse'
      package_location_ids = [package.origin_area&.location_id, package.destination_area&.location_id].compact
      (accessible_locations & package_location_ids).any?
    when 'admin'
      true
    else
      false
    end
  end

  # EXISTING: Package delivery related methods
  def pending_packages_count
    packages.where(state: ['pending_unpaid', 'pending']).count
  end

  def active_packages_count
    packages.where(state: ['submitted', 'in_transit']).count
  end

  def delivered_packages_count
    packages.where(state: 'delivered').count
  end

  # NEW: Scanning statistics methods
  def scanning_stats(date_range = Date.current.all_day)
    return {} unless can_scan_packages?

    events = package_tracking_events.where(created_at: date_range)
    
    {
      total_scans: events.count,
      packages_scanned: events.select(:package_id).distinct.count,
      actions_performed: events.group(:event_type).count,
      last_scan_time: events.maximum(:created_at),
      average_scans_per_hour: calculate_average_scans_per_hour(events, date_range)
    }
  end

  def daily_scanning_stats
    scanning_stats(Date.current.all_day)
  end

  def weekly_scanning_stats
    scanning_stats(1.week.ago..Time.current)
  end

  def monthly_scanning_stats
    scanning_stats(1.month.ago..Time.current)
  end

  # NEW: Performance metrics
  def performance_metrics(period = 1.month)
    return {} unless staff?

    start_date = period.ago
    events = package_tracking_events.where(created_at: start_date..Time.current)
    
    base_metrics = {
      total_packages_handled: events.select(:package_id).distinct.count,
      total_actions: events.count,
      period_start: start_date,
      period_end: Time.current,
      role: primary_role
    }

    case primary_role
    when 'agent'
      agent_specific_metrics(events, base_metrics)
    when 'rider'
      rider_specific_metrics(events, base_metrics)
    when 'warehouse'
      warehouse_specific_metrics(events, base_metrics)
    when 'admin'
      admin_specific_metrics(events, base_metrics)
    else
      base_metrics
    end
  end

  # NEW: Role assignment methods
  def assign_to_area(area, role_type = nil)
    role_type ||= primary_role
    
    case role_type
    when 'agent'
      add_role(:agent) unless has_role?(:agent)
      agents.find_or_create_by(area: area) do |agent|
        agent.name = full_name
        agent.phone = phone_number
        agent.active = true
      end
    when 'rider'
      add_role(:rider) unless has_role?(:rider)
      riders.find_or_create_by(area: area) do |rider|
        rider.name = full_name
        rider.phone = phone_number
        rider.active = true
      end
    end
  end

  def assign_to_location(location)
    add_role(:warehouse) unless has_role?(:warehouse)
    
    warehouse_staff.find_or_create_by(location: location) do |staff|
      staff.name = full_name
      staff.phone = phone_number
      staff.active = true
    end
  end

  def remove_from_area(area, role_type = nil)
    role_type ||= primary_role
    
    case role_type
    when 'agent'
      agents.where(area: area).destroy_all
    when 'rider'
      riders.where(area: area).destroy_all
    end
  end

  def remove_from_location(location)
    warehouse_staff.where(location: location).destroy_all
  end

  # NEW: Account management
  def activate!
    update!(last_seen_at: Time.current)
    activate_role_records
  end

  def deactivate!
    update!(last_seen_at: 30.days.ago)
    deactivate_role_records
  end

  # JSON serialization
  def as_json(options = {})
    result = super(options.except(:include_role_details, :include_stats))
    
    # Always include basic info
    result.merge!(
      'primary_role' => primary_role,
      'role_display' => role_display_name,
      'role_description' => role_description,
      'can_scan_packages' => can_scan_packages?,
      'available_actions' => available_actions,
      'is_active' => active?,
      'full_name' => full_name,
      'display_name' => display_name,
      'initials' => initials,
      'roles' => roles.pluck(:name)
    )
    
    # Include role-specific details if requested
    if options[:include_role_details]
      result.merge!(
        'accessible_areas' => accessible_areas,
        'accessible_locations' => accessible_locations,
        'role_records' => serialize_role_records
      )
    end
    
    # Include scanning stats if requested
    if options[:include_stats]
      result.merge!(
        'daily_stats' => daily_scanning_stats,
        'performance_metrics' => performance_metrics
      )
    end
    
    result
  end

  private

  def assign_default_role
    add_role(:client) if roles.blank?
  end

  def normalize_phone
    return unless phone_number.present?
    
    # Remove all non-digit characters except +
    self.phone_number = phone_number.gsub(/[^\d\+]/, '')
    
    # Add country code if missing (assuming Kenya +254)
    if phone_number.match(/^[07]/) && phone_number.length == 10
      self.phone_number = "+254#{phone_number[1..-1]}"
    elsif phone_number.match(/^[7]/) && phone_number.length == 9
      self.phone_number = "+254#{phone_number}"
    end
  end

  def activate_role_records
    agents.update_all(active: true) if has_role?(:agent)
    riders.update_all(active: true) if has_role?(:rider)
    warehouse_staff.update_all(active: true) if has_role?(:warehouse)
  end

  def deactivate_role_records
    agents.update_all(active: false) if has_role?(:agent)
    riders.update_all(active: false) if has_role?(:rider)
    warehouse_staff.update_all(active: false) if has_role?(:warehouse)
  end

  def calculate_average_scans_per_hour(events, date_range)
    return 0 if events.empty?
    
    total_hours = (date_range.end - date_range.begin) / 1.hour
    total_hours = 1 if total_hours < 1 # Avoid division by zero
    
    (events.count / total_hours).round(2)
  end

  def agent_specific_metrics(events, base_metrics)
    print_events = events.where(event_type: 'printed_by_agent')
    
    base_metrics.merge(
      labels_printed: print_events.count,
      packages_printed: print_events.select(:package_id).distinct.count,
      average_prints_per_day: (print_events.count / 30.0).round(2),
      areas_served: agents.joins(:area).pluck('areas.name').uniq
    )
  end

  def rider_specific_metrics(events, base_metrics)
    collect_events = events.where(event_type: 'collected_by_rider')
    deliver_events = events.where(event_type: 'delivered_by_rider')
    
    base_metrics.merge(
      packages_collected: collect_events.select(:package_id).distinct.count,
      packages_delivered: deliver_events.select(:package_id).distinct.count,
      collection_rate: calculate_rate(collect_events),
      delivery_rate: calculate_rate(deliver_events),
      routes_covered: riders.joins(:area).pluck('areas.name').uniq
    )
  end

  def warehouse_specific_metrics(events, base_metrics)
    process_events = events.where(event_type: 'processed_by_warehouse')
    print_events = events.where(event_type: 'printed_by_warehouse')
    
    base_metrics.merge(
      packages_processed: process_events.select(:package_id).distinct.count,
      labels_printed: print_events.count,
      processing_rate: calculate_rate(process_events),
      locations_managed: warehouse_staff.joins(:location).pluck('locations.name').uniq
    )
  end

  def admin_specific_metrics(events, base_metrics)
    base_metrics.merge(
      system_actions: events.count,
      packages_managed: events.select(:package_id).distinct.count,
      action_types: events.group(:event_type).count,
      coverage: 'System-wide'
    )
  end

  def calculate_rate(events)
    return 0 if events.empty?
    
    days = ((events.maximum(:created_at) - events.minimum(:created_at)) / 1.day).ceil
    days = 1 if days < 1
    
    (events.count / days.to_f).round(2)
  end

  def serialize_role_records
    result = {}
    
    if has_role?(:agent)
      result[:agents] = agents.includes(:area).map do |agent|
        {
          id: agent.id,
          area: agent.area&.name,
          active: agent.active?
        }
      end
    end
    
    if has_role?(:rider)
      result[:riders] = riders.includes(:area).map do |rider|
        {
          id: rider.id,
          area: rider.area&.name,
          active: rider.active?
        }
      end
    end
    
    if has_role?(:warehouse)
      result[:warehouse_staff] = warehouse_staff.includes(:location).map do |staff|
        {
          id: staff.id,
          location: staff.location&.name,
          active: staff.active?
        }
      end
    end
    
    result
  end
end