# app/models/user.rb - Complete Fixed Version
class User < ApplicationRecord
  # ===========================================
  # 🔐 DEVISE CONFIGURATION
  # ===========================================
  
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :jwt_authenticatable,
         :omniauthable,
         jwt_revocation_strategy: Devise::JWT::RevocationStrategies::Null,
         omniauth_providers: [:google_oauth2]

  # ===========================================
  # 📎 ASSOCIATIONS
  # ===========================================
  
  # ActiveStorage for avatar
  has_one_attached :avatar

  # Business relationships
  has_many :owned_businesses, class_name: "Business", foreign_key: "owner_id"
  has_many :user_businesses
  has_many :businesses, through: :user_businesses

  # Package delivery system relationships
  has_many :packages, dependent: :destroy
  has_many :agents, dependent: :destroy
  has_many :riders, dependent: :destroy
  has_many :warehouse_staff, dependent: :destroy
  has_many :package_tracking_events, dependent: :destroy
  has_many :package_print_logs, dependent: :destroy

  # Messaging system relationships
  has_many :conversation_participants, dependent: :destroy
  has_many :conversations, through: :conversation_participants
  has_many :messages, dependent: :destroy

  # Rolify for roles
  rolify

  # ===========================================
  # 🔍 VALIDATIONS
  # ===========================================
  
  validates :email, presence: true, uniqueness: true
  validates :first_name, presence: true, length: { minimum: 2, maximum: 100 }
  validates :phone_number, format: { with: /\A\+?[0-9\s\-\(\)]+\z/, message: "Invalid phone format" }, allow_blank: true
  validates :provider, inclusion: { in: [nil, 'google_oauth2'] }
  validates :uid, uniqueness: { scope: :provider }, allow_nil: true

  # ===========================================
  # 🔄 CALLBACKS
  # ===========================================
  
  after_create :assign_default_role
  before_validation :normalize_phone

  # ===========================================
  # 🔍 SCOPES
  # ===========================================
  
  scope :active, -> { where.not(last_seen_at: nil).where('last_seen_at > ?', 30.days.ago) }
  scope :inactive, -> { where(last_seen_at: nil).or(where('last_seen_at <= ?', 30.days.ago)) }
  scope :with_scanning_activity, -> { joins(:package_tracking_events).distinct }
  scope :recent_scanners, -> { joins(:package_tracking_events).where(package_tracking_events: { created_at: 1.week.ago.. }).distinct }
  scope :google_users, -> { where(provider: 'google_oauth2') }
  scope :regular_users, -> { where(provider: nil) }

  # ===========================================
  # 🔐 JWT METHODS
  # ===========================================

  def jwt_subject
    id
  end

  def jwt_payload
    {
      'role' => primary_role,
      'email' => email,
      'name' => full_name
    }
  end

  # ===========================================
  # 🔐 GOOGLE OAUTH METHODS
  # ===========================================

  def self.from_omniauth(auth)
    Rails.logger.info "Google OAuth callback received for email: #{auth.info.email}"
    
    user = find_by(email: auth.info.email)
    
    if user
      user.update_google_oauth_info(auth)
      Rails.logger.info "Updated existing user: #{user.email}"
    else
      user = create_from_google_oauth(auth)
      Rails.logger.info "Created new user from Google OAuth: #{user.email}"
    end
    
    user
  end

  def self.create_from_google_oauth(auth)
    password = Devise.friendly_token[0, 20]
    
    user = create!(
      email: auth.info.email,
      password: password,
      password_confirmation: password,
      first_name: auth.info.first_name || auth.info.name&.split&.first || 'Google',
      last_name: auth.info.last_name || auth.info.name&.split&.last || 'User',
      provider: auth.provider,
      uid: auth.uid,
      confirmed_at: Time.current,
      google_image_url: auth.info.image
    )
    
    user.attach_google_avatar(auth.info.image) if auth.info.image.present?
    user
  end

  def update_google_oauth_info(auth)
    update!(
      provider: auth.provider,
      uid: auth.uid,
      google_image_url: auth.info.image,
      first_name: first_name.present? ? first_name : (auth.info.first_name || auth.info.name&.split&.first),
      last_name: last_name.present? ? last_name : (auth.info.last_name || auth.info.name&.split&.last),
      confirmed_at: confirmed_at || Time.current
    )
    
    attach_google_avatar(auth.info.image) if auth.info.image.present? && !avatar.attached?
  end

  def google_user?
    provider == 'google_oauth2' && uid.present?
  end

  def password_required?
    return false if google_user? && encrypted_password.blank?
    super
  end

  def needs_password?
    google_user? && encrypted_password.blank?
  end

  def set_password(password, password_confirmation)
    return false unless needs_password?
    
    self.password = password
    self.password_confirmation = password_confirmation
    save
  end

  def attach_google_avatar(image_url)
    return unless image_url.present?
    
    begin
      require 'open-uri'
      downloaded_image = URI.open(image_url)
      avatar.attach(
        io: downloaded_image,
        filename: "google_avatar_#{id}.jpg",
        content_type: 'image/jpeg'
      )
      Rails.logger.info "Attached Google avatar for user: #{email}"
    rescue => e
      Rails.logger.error "Failed to attach Google avatar for user #{email}: #{e.message}"
    end
  end

  # ===========================================
  # 👤 USER STATUS METHODS - FIXED
  # ===========================================

  def mark_online!
    # Use update_columns to bypass validations during login
    update_columns(online: true, last_seen_at: Time.current)
  rescue => e
    Rails.logger.error "Failed to mark user #{id} online: #{e.message}"
    false
  end

  def mark_offline!
    # Use update_columns to bypass validations during logout  
    update_columns(online: false, last_seen_at: Time.current)
  rescue => e
    Rails.logger.error "Failed to mark user #{id} offline: #{e.message}"
    false
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

  def active?
    last_seen_at.present? && last_seen_at > 30.days.ago
  end

  # ===========================================
  # 🎭 ROLE METHODS
  # ===========================================

  def support_agent?
    has_role?(:support)
  end

  def client?
    has_role?(:client)
  end

  def admin?
    has_role?(:admin)
  end

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

  def customer?
    client?
  end

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

  # ===========================================
  # 📦 PACKAGE ACCESS METHODS - FIXED
  # ===========================================

  def accessible_packages
    case primary_role
    when 'client'
      # Clients can only see their own packages
      packages
    when 'agent'
      # Agents can see packages in their areas
      if respond_to?(:accessible_areas) && accessible_areas.any?
        area_ids = accessible_areas.pluck(:id)
        Package.where(origin_area_id: area_ids)
               .or(Package.where(destination_area_id: area_ids))
      else
        # Fallback: if no area restrictions, agents can see all packages
        Package.all
      end
    when 'rider'
      # Riders can see packages in their delivery areas
      if respond_to?(:accessible_areas) && accessible_areas.any?
        area_ids = accessible_areas.pluck(:id)
        Package.where(origin_area_id: area_ids)
               .or(Package.where(destination_area_id: area_ids))
      else
        # Fallback: if no area restrictions, riders can see all packages
        Package.all
      end
    when 'warehouse'
      # Warehouse staff can see all packages
      Package.all
    when 'admin'
      # Admins can see all packages
      Package.all
    when 'support'
      # Support can see all packages for customer service
      Package.all
    else
      # Default: clients can only see their own packages
      packages
    end
  end

  def accessible_areas
    case primary_role
    when 'agent'
      if respond_to?(:agents) && agents.any?
        Area.where(id: agents.pluck(:area_id))
      else
        # If no specific agent records, return all areas (fallback)
        Area.all
      end
    when 'rider'
      if respond_to?(:riders) && riders.any?
        Area.where(id: riders.pluck(:area_id))
      else
        # If no specific rider records, return all areas (fallback)
        Area.all
      end
    when 'warehouse'
      # Warehouse staff can access all areas in their locations
      if respond_to?(:warehouse_staff) && warehouse_staff.any?
        location_ids = warehouse_staff.pluck(:location_id)
        Area.where(location_id: location_ids)
      else
        # If no specific warehouse records, return all areas (fallback)
        Area.all
      end
    when 'admin'
      # Admins can access all areas
      Area.all
    else
      # Clients and others have no specific area access
      Area.none
    end
  rescue => e
    Rails.logger.error "Error getting accessible areas for user #{id}: #{e.message}"
    Area.none
  end

  def accessible_locations
    case primary_role
    when 'warehouse'
      if respond_to?(:warehouse_staff) && warehouse_staff.any?
        Location.where(id: warehouse_staff.pluck(:location_id))
      else
        Location.all
      end
    when 'admin'
      Location.all
    else
      # For agents and riders, get locations through their areas
      accessible_areas.includes(:location).map(&:location).uniq.compact
    end
  rescue => e
    Rails.logger.error "Error getting accessible locations for user #{id}: #{e.message}"
    []
  end

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

  def can_access_package?(package)
    case primary_role
    when 'client'
      package.user_id == id
    when 'agent'
      operates_in_area?(package.origin_area_id) || operates_in_area?(package.destination_area_id)
    when 'rider'
      operates_in_area?(package.origin_area_id) || operates_in_area?(package.destination_area_id)
    when 'warehouse', 'admin', 'support'
      true
    else
      false
    end
  end

  def operates_in_area?(area_id)
    return true if admin? # Admins can operate anywhere
    return false unless area_id # No area specified
    
    accessible_areas.exists?(id: area_id)
  rescue => e
    Rails.logger.error "Error checking area operation for user #{id}: #{e.message}"
    admin? # Fail open for admins, closed for others
  end

  def has_warehouse_access?
    warehouse? || admin?
  end

  # ===========================================
  # 📊 PACKAGE STATISTICS
  # ===========================================

  def pending_packages_count
    case primary_role
    when 'client'
      packages.where(state: ['pending_unpaid', 'pending']).count
    else
      accessible_packages.where(state: ['pending_unpaid', 'pending']).count
    end
  rescue => e
    Rails.logger.error "Error getting pending packages count: #{e.message}"
    0
  end

  def active_packages_count
    case primary_role
    when 'client'
      packages.where(state: ['submitted', 'in_transit']).count
    else
      accessible_packages.where(state: ['submitted', 'in_transit']).count
    end
  rescue => e
    Rails.logger.error "Error getting active packages count: #{e.message}"
    0
  end

  def delivered_packages_count
    case primary_role
    when 'client'
      packages.where(state: 'delivered').count
    else
      accessible_packages.where(state: 'delivered').count
    end
  rescue => e
    Rails.logger.error "Error getting delivered packages count: #{e.message}"
    0
  end

  # ===========================================
  # 🔧 HELPER METHODS
  # ===========================================

  def available_actions
    actions = []
    
    case primary_role
    when 'client'
      actions = ['create_package', 'view_own_packages', 'track_packages']
    when 'agent'
      actions = ['view_packages', 'print_labels', 'collect_packages']
    when 'rider'
      actions = ['view_packages', 'collect_packages', 'deliver_packages']
    when 'warehouse'
      actions = ['view_all_packages', 'process_packages', 'print_labels', 'manage_inventory']
    when 'admin'
      actions = ['view_all_packages', 'manage_packages', 'manage_users', 'manage_system']
    when 'support'
      actions = ['view_all_packages', 'manage_conversations', 'assist_customers']
    end
    
    actions
  end

  # Stats methods for dashboard
  def daily_scanning_stats
    return {} unless staff?
    
    {
      scans_today: package_tracking_events.where(created_at: Date.current.all_day).count,
      packages_processed: package_tracking_events.where(created_at: Date.current.all_day)
                                                .select(:package_id).distinct.count
    }
  rescue => e
    Rails.logger.error "Error getting daily scanning stats: #{e.message}"
    {}
  end

  def weekly_scanning_stats
    return {} unless staff?
    
    {
      scans_this_week: package_tracking_events.where(created_at: 1.week.ago..Time.current).count,
      packages_processed: package_tracking_events.where(created_at: 1.week.ago..Time.current)
                                                .select(:package_id).distinct.count
    }
  rescue => e
    Rails.logger.error "Error getting weekly scanning stats: #{e.message}"
    {}
  end

  def monthly_scanning_stats
    return {} unless staff?
    
    {
      scans_this_month: package_tracking_events.where(created_at: 1.month.ago..Time.current).count,
      packages_processed: package_tracking_events.where(created_at: 1.month.ago..Time.current)
                                                .select(:package_id).distinct.count
    }
  rescue => e
    Rails.logger.error "Error getting monthly scanning stats: #{e.message}"
    {}
  end

  # ===========================================
  # 🔧 JSON SERIALIZATION
  # ===========================================

  def as_json(options = {})
    result = super(options.except(:include_role_details, :include_stats))
    
    result.merge!(
      'primary_role' => primary_role,
      'role_display' => role_display_name,
      'can_scan_packages' => can_scan_packages?,
      'is_active' => active?,
      'full_name' => full_name,
      'display_name' => display_name,
      'initials' => initials,
      'roles' => roles.pluck(:name),
      'google_user' => google_user?,
      'needs_password' => needs_password?
    )
    
    result
  end

  private

  def assign_default_role
    add_role(:client) if roles.blank?
  end

  def normalize_phone
    return unless phone_number.present?
    
    self.phone_number = phone_number.gsub(/[^\d\+]/, '')
    
    if phone_number.match(/^[07]/) && phone_number.length == 10
      self.phone_number = "+254#{phone_number[1..-1]}"
    elsif phone_number.match(/^[7]/) && phone_number.length == 9
      self.phone_number = "+254#{phone_number}"
    end
  end
end