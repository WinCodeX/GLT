# app/models/user.rb - Enhanced with Google OAuth + JWT

class User < ApplicationRecord
  # ===========================================
  # 🔐 DEVISE CONFIGURATION (JWT RE-ENABLED)
  # ===========================================
  
  # Include Devise modules with JWT support
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :jwt_authenticatable,  # Re-enabled JWT
         :omniauthable,
         jwt_revocation_strategy: Devise::JWT::RevocationStrategies::Null,
         omniauth_providers: [:google_oauth2]

  # ActiveStorage for avatar
  has_one_attached :avatar

  # Business relationships (existing)
  has_many :owned_businesses, class_name: "Business", foreign_key: "owner_id"
  has_many :user_businesses
  has_many :businesses, through: :user_businesses

  # Package delivery system relationships (existing + new scanning)
  has_many :packages, dependent: :destroy
  
  # Scanning-related associations
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

  # ===========================================
  # 🔍 VALIDATIONS
  # ===========================================
  
  validates :email, presence: true, uniqueness: true
  validates :first_name, presence: true, length: { minimum: 2, maximum: 100 }
  validates :phone_number, format: { with: /\A\+?[0-9\s\-\(\)]+\z/, message: "Invalid phone format" }, allow_blank: true

  # Google OAuth fields validation
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
  # 🔐 JWT METHODS (Re-enabled)
  # ===========================================

  # JWT subject (required by devise-jwt)
  def jwt_subject
    id
  end

  # JWT payload (optional - add custom claims)
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

  # Main method called by Devise when Google OAuth succeeds
  def self.from_omniauth(auth)
    Rails.logger.info "Google OAuth callback received for email: #{auth.info.email}"
    
    # Find existing user by email or create new one
    user = find_by(email: auth.info.email)
    
    if user
      # Update existing user with Google info
      user.update_google_oauth_info(auth)
      Rails.logger.info "Updated existing user: #{user.email}"
    else
      # Create new user from Google OAuth
      user = create_from_google_oauth(auth)
      Rails.logger.info "Created new user from Google OAuth: #{user.email}"
    end
    
    user
  end

  # Create new user from Google OAuth data
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
      confirmed_at: Time.current, # Auto-confirm Google users
      google_image_url: auth.info.image
    )
    
    # Attach Google profile image if available
    user.attach_google_avatar(auth.info.image) if auth.info.image.present?
    
    user
  end

  # Update existing user with Google OAuth info
  def update_google_oauth_info(auth)
    update!(
      provider: auth.provider,
      uid: auth.uid,
      google_image_url: auth.info.image,
      # Update names only if they're currently blank
      first_name: first_name.present? ? first_name : (auth.info.first_name || auth.info.name&.split&.first),
      last_name: last_name.present? ? last_name : (auth.info.last_name || auth.info.name&.split&.last),
      confirmed_at: confirmed_at || Time.current # Confirm if not already confirmed
    )
    
    # Update avatar only if user doesn't have one
    attach_google_avatar(auth.info.image) if auth.info.image.present? && !avatar.attached?
  end

  # Check if user signed up via Google OAuth
  def google_user?
    provider == 'google_oauth2' && uid.present?
  end

  # Check if user can sign in with password (not Google-only)
  def password_required?
    return false if google_user? && encrypted_password.blank?
    super
  end

  # Check if user needs to set a password
  def needs_password?
    google_user? && encrypted_password.blank?
  end

  # Allow Google users to set password later
  def set_password(password, password_confirmation)
    return false unless needs_password?
    
    self.password = password
    self.password_confirmation = password_confirmation
    save
  end

  # Attach Google profile image as avatar
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
  # 👤 USER INFO METHODS
  # ===========================================

  def mark_online!
  update_columns(online: true, last_seen_at: Time.current)  # ✅ BYPASSES VALIDATIONS
end

def mark_offline!
  update_columns(online: false, last_seen_at: Time.current)  # ✅ BYPASSES VALIDATIONS
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
    client? # Maps client role to customer for support system
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
  # 📱 PACKAGE ACCESS METHODS
  # ===========================================

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
      true # agents can access packages in their areas
    when 'rider'
      true # riders can access packages for delivery
    when 'warehouse'
      true # warehouse staff can access all packages
    when 'admin'
      true
    else
      false
    end
  end

  # ===========================================
  # 📊 PACKAGE STATISTICS
  # ===========================================

  def pending_packages_count
    packages.where(state: ['pending_unpaid', 'pending']).count
  end

  def active_packages_count
    packages.where(state: ['submitted', 'in_transit']).count
  end

  def delivered_packages_count
    packages.where(state: 'delivered').count
  end

  # ===========================================
  # 🔧 JSON SERIALIZATION
  # ===========================================

  def as_json(options = {})
    result = super(options.except(:include_role_details, :include_stats))
    
    # Always include basic info
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

  # ===========================================
  # 🔧 PRIVATE METHODS
  # ===========================================

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
end