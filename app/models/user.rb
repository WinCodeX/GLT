# app/models/user.rb - With Wallet Associations
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
  has_many :owned_businesses, class_name: "Business", foreign_key: "owner_id", dependent: :destroy
  has_many :user_businesses, dependent: :destroy
  has_many :businesses, through: :user_businesses
  has_many :business_invites, foreign_key: "inviter_id", dependent: :destroy

  # Package delivery system relationships
  has_many :packages, dependent: :destroy
  has_many :agents, dependent: :destroy
  has_many :riders, dependent: :destroy
  has_many :warehouse_staff, dependent: :destroy
  has_many :package_tracking_events, dependent: :destroy
  has_many :package_print_logs, dependent: :destroy

  has_many :push_tokens, dependent: :destroy
  has_many :notifications, dependent: :destroy

  # Messaging system relationships
  has_many :conversation_participants, dependent: :destroy
  has_many :conversations, through: :conversation_participants
  has_many :messages, dependent: :destroy

  # Wallet relationships - NEW
  has_one :wallet, dependent: :destroy
  has_many :wallet_transactions, through: :wallet, source: :transactions
  has_many :withdrawals, through: :wallet

  # Rider reports - NEW
  has_many :rider_reports, dependent: :destroy

  # Rolify for roles
  rolify

  # ===========================================
  # 🔍 VALIDATIONS
  # ===========================================
  
  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :first_name, presence: true, length: { minimum: 2, maximum: 100 }
  validates :last_name, length: { maximum: 100 }, allow_blank: true
  validates :phone_number, format: { 
    with: /\A\+?[0-9\s\-\(\)]+\z/, 
    message: "Invalid phone format" 
  }, allow_blank: true
  validates :provider, inclusion: { in: [nil, 'google_oauth2'] }
  validates :uid, uniqueness: { scope: :provider }, allow_nil: true

  # Custom validation for phone number format after normalization
  validate :valid_normalized_phone_number

  # ===========================================
  # 🔄 CALLBACKS
  # ===========================================
  
  after_create :assign_default_role
  after_create :create_user_wallet
  before_validation :normalize_phone
  before_validation :normalize_email

  # ===========================================
  # 🔍 SCOPES
  # ===========================================
  
  scope :active, -> { where.not(last_seen_at: nil).where('last_seen_at > ?', 30.days.ago) }
  scope :inactive, -> { where(last_seen_at: nil).or(where('last_seen_at <= ?', 30.days.ago)) }
  scope :with_scanning_activity, -> { joins(:package_tracking_events).distinct }
  scope :recent_scanners, -> { joins(:package_tracking_events).where(package_tracking_events: { created_at: 1.week.ago.. }).distinct }
  scope :google_users, -> { where(provider: 'google_oauth2') }
  scope :regular_users, -> { where(provider: nil) }
  scope :without_wallet, -> { left_outer_joins(:wallet).where(wallets: { id: nil }) }

  # ===========================================
  # 🎭 PUSH NOTIFICATION METHODS
  # ===========================================

  def active_push_tokens
    push_tokens.active
  end
  
  def has_push_notifications_enabled?
    active_push_tokens.any?
  end
  
  def expo_push_tokens
    active_push_tokens.expo_tokens
  end

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
    
    # Normalize email for consistent lookup
    normalized_email = auth.info.email.to_s.downcase.strip
    user = find_by(email: normalized_email)
    
    if user
      user.update_google_oauth_info(auth)
      Rails.logger.info "Updated existing user: #{user.email}"
    else
      user = create_from_google_oauth(auth)
      Rails.logger.info "Created new user from Google OAuth: #{user.email}"
    end
    
    user
  rescue => e
    Rails.logger.error "Error processing Google OAuth for #{auth.info.email}: #{e.message}"
    nil
  end

  def self.create_from_google_oauth(auth)
    password = Devise.friendly_token[0, 20]
    normalized_email = auth.info.email.to_s.downcase.strip
    
    user = create!(
      email: normalized_email,
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
  rescue => e
    Rails.logger.error "Error creating user from Google OAuth: #{e.message}"
    raise e
  end

  def update_google_oauth_info(auth)
    update_attrs = {
      provider: auth.provider,
      uid: auth.uid,
      google_image_url: auth.info.image,
      confirmed_at: confirmed_at || Time.current
    }
    
    # Only update names if they're currently blank
    if first_name.blank?
      update_attrs[:first_name] = auth.info.first_name || auth.info.name&.split&.first || first_name
    end
    
    if last_name.blank?
      update_attrs[:last_name] = auth.info.last_name || auth.info.name&.split&.last || last_name
    end
    
    update!(update_attrs)
    
    attach_google_avatar(auth.info.image) if auth.info.image.present? && !avatar.attached?
  rescue => e
    Rails.logger.error "Error updating Google OAuth info for user #{id}: #{e.message}"
    false
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
    return false if password.blank?
    
    self.password = password
    self.password_confirmation = password_confirmation
    save
  end

  def attach_google_avatar(image_url)
    return unless image_url.present?
    return if avatar.attached? # Don't overwrite existing avatar
    
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
  # 👤 USER STATUS METHODS
  # ===========================================

  def mark_online!
    update(online: true, last_seen_at: Time.current)
  rescue => e
    Rails.logger.error "Failed to mark user #{id} online: #{e.message}"
    false
  end

  def mark_offline!
    update(online: false, last_seen_at: Time.current)
  rescue => e
    Rails.logger.error "Failed to mark user #{id} offline: #{e.message}"
    false
  end

  def full_name
    if first_name.present? || last_name.present?
      "#{first_name} #{last_name}".strip
    else
      email.split('@').first.humanize
    end
  end

  def display_name
    name = full_name
    return name if name.present? && name != email.split('@').first.humanize
    email.split('@').first.humanize
  end

  def initials
    names = [first_name, last_name].compact.reject(&:blank?)
    if names.any?
      names.map { |name| name.first.upcase }.join
    else
      email.first(2).upcase
    end
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

  def support_staff?
    has_role?(:support) || has_role?(:admin)
  end

  def can_handle_support?
    support_staff?
  end

  # Conversation access methods
  def accessible_conversations
    if admin? || support_staff?
      Conversation.all
    else
      conversations
    end
  end

  def support_conversations
    conversations.where(conversation_type: 'support_ticket')
  end

  def initiated_conversations
    conversations
  end

  # ===========================================
  # 🏢 BUSINESS METHODS
  # ===========================================

  def can_create_business?
    true # All users can create businesses
  end

  def can_manage_business?(business)
    return false unless business
    business.owner_id == id || admin?
  end

  def can_join_business?(business)
    return false unless business
    return false if business.owner_id == id # Can't join own business
    !businesses.include?(business) # Can't join if already a member
  end

  def business_role_for(business)
    return 'owner' if business.owner_id == id
    
    user_business = user_businesses.find_by(business: business)
    user_business&.role || 'none'
  end

  def owns_business?(business)
    business.owner_id == id
  end

  def member_of_business?(business)
    businesses.include?(business)
  end

  # ===========================================
  # 💰 WALLET METHODS - NEW
  # ===========================================

  def ensure_wallet!
    return wallet if wallet.present?
    create_user_wallet
    reload.wallet
  end

  def wallet_balance
    wallet&.balance || 0
  end

  def pending_balance
    wallet&.pending_balance || 0
  end

  def available_balance
    wallet&.available_balance || 0
  end

  def can_withdraw?(amount)
    wallet.present? && wallet.can_withdraw?(amount)
  end

  def recent_wallet_transactions(limit = 10)
    return [] unless wallet
    wallet.recent_transactions(limit)
  end

  # ===========================================
  # 📦 PACKAGE ACCESS METHODS
  # ===========================================

  def accessible_packages
    case primary_role
    when 'client'
      packages
    when 'agent'
      if respond_to?(:accessible_areas) && accessible_areas.any?
        area_ids = accessible_areas.pluck(:id)
        Package.where(origin_area_id: area_ids)
               .or(Package.where(destination_area_id: area_ids))
      else
        Package.all
      end
    when 'rider'
      if respond_to?(:accessible_areas) && accessible_areas.any?
        area_ids = accessible_areas.pluck(:id)
        Package.where(origin_area_id: area_ids)
               .or(Package.where(destination_area_id: area_ids))
      else
        Package.all
      end
    when 'warehouse', 'admin', 'support'
      Package.all
    else
      packages
    end
  rescue => e
    Rails.logger.error "Error getting accessible packages for user #{id}: #{e.message}"
    case primary_role
    when 'client'
      packages
    else
      Package.none
    end
  end

  def accessible_areas
    case primary_role
    when 'agent'
      if agents.any?
        Area.where(id: agents.pluck(:area_id).compact)
      else
        Area.all
      end
    when 'rider'
      if riders.any?
        Area.where(id: riders.pluck(:area_id).compact)
      else
        Area.all
      end
    when 'warehouse'
      if warehouse_staff.any?
        location_ids = warehouse_staff.pluck(:location_id).compact
        Area.where(location_id: location_ids)
      else
        Area.all
      end
    when 'admin'
      Area.all
    else
      Area.none
    end
  rescue => e
    Rails.logger.error "Error getting accessible areas for user #{id}: #{e.message}"
    Area.none
  end

  def accessible_locations
    case primary_role
    when 'warehouse'
      if warehouse_staff.any?
        Location.where(id: warehouse_staff.pluck(:location_id).compact)
      else
        Location.all
      end
    when 'admin'
      Location.all
    else
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
    return false unless package
    
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
    return true if admin?
    return false unless area_id
    
    accessible_areas.exists?(id: area_id)
  rescue => e
    Rails.logger.error "Error checking area operation for user #{id}: #{e.message}"
    admin?
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
      actions = ['create_package', 'view_own_packages', 'track_packages', 'create_business', 'manage_own_businesses']
    when 'agent'
      actions = ['view_packages', 'print_labels', 'collect_packages']
    when 'rider'
      actions = ['view_packages', 'collect_packages', 'deliver_packages']
    when 'warehouse'
      actions = ['view_all_packages', 'process_packages', 'print_labels', 'manage_inventory']
    when 'admin'
      actions = ['view_all_packages', 'manage_packages', 'manage_users', 'manage_system', 'manage_all_businesses']
    when 'support'
      actions = ['view_all_packages', 'manage_conversations', 'assist_customers']
    end
    
    actions
  end

  def daily_scanning_stats
    return {} unless staff?
    
    {
      scans_today: package_tracking_events.where(created_at: Date.current.all_day).count,
      packages_processed: package_tracking_events.where(created_at: Date.current.all_day)
                                                .select(:package_id).distinct.count
    }
  rescue => e
    Rails.logger.error "Error getting daily scanning stats: #{e.message}"
    { scans_today: 0, packages_processed: 0 }
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
    { scans_this_week: 0, packages_processed: 0 }
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
    { scans_this_month: 0, packages_processed: 0 }
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
      'needs_password' => needs_password?,
      'owned_businesses_count' => owned_businesses.count,
      'joined_businesses_count' => businesses.count,
      'wallet_balance' => wallet_balance,
      'has_wallet' => wallet.present?
    )
    
    result
  end

  private

  def assign_default_role
    begin
      add_role(:client) if roles.blank?
    rescue => e
      Rails.logger.error "Failed to assign default role to user #{id}: #{e.message}"
      # Don't fail user creation if role assignment fails
    end
  end

  def create_user_wallet
    return if wallet.present?
    
    begin
      Wallet.create!(
        user: self,
        balance: 0.0,
        pending_balance: 0.0,
        total_credited: 0.0,
        total_debited: 0.0,
        is_active: true
      )
      Rails.logger.info "Created wallet for user #{id}"
    rescue => e
      Rails.logger.error "Failed to create wallet for user #{id}: #{e.message}"
      # Don't fail user creation if wallet creation fails
    end
  end

  def normalize_phone
    return unless phone_number.present?
    
    # Remove all non-digit characters except +
    cleaned = phone_number.gsub(/[^\d\+]/, '')
    
    # Handle Kenyan phone numbers
    if cleaned.match(/^0[17]\d{8}$/) # 0712345678
      self.phone_number = "+254#{cleaned[1..-1]}"
    elsif cleaned.match(/^[17]\d{8}$/) # 712345678
      self.phone_number = "+254#{cleaned}"
    elsif cleaned.match(/^254[17]\d{8}$/) # 254712345678
      self.phone_number = "+#{cleaned}"
    elsif cleaned.match(/^\+254[17]\d{8}$/) # +254712345678
      self.phone_number = cleaned
    else
      # Keep original if it doesn't match expected patterns
      self.phone_number = cleaned.presence || phone_number
    end
  end

  def normalize_email
    return unless email.present?
    self.email = email.downcase.strip
  end

  def valid_normalized_phone_number
    return if phone_number.blank?
    
    # After normalization, ensure it matches the expected format
    unless phone_number.match(/^\+254[17]\d{8}$/)
      errors.add(:phone_number, "must be a valid Kenyan phone number (e.g., +254712345678)")
    end
  end
end