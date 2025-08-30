# app/serializers/user_serializer.rb - Enhanced with Google OAuth integration

class UserSerializer < ActiveModel::Serializer
  include Rails.application.routes.url_helpers
  include UrlHostHelper
  include AvatarHelper

  # ===========================================
  # 📋 CORE ATTRIBUTES
  # ===========================================
  
  attributes :id, :email, :first_name, :last_name, :display_name, :full_name, 
             :initials, :username, :phone, :phone_number,
             
             # Avatar and profile
             :google_image_url, :profile_complete,
             
             # Role and permissions
             :roles, :primary_role, :role_display, :role_description,
             :available_actions,
             
             # Authentication and security
             :google_user, :needs_password, :provider, :confirmed,
             :is_active, :online, :account_status,
             
             # Package delivery permissions
             :can_scan_packages, :can_print_labels, :can_manage_packages,
             :can_view_all_packages,
             
             # Package statistics
             :pending_packages_count, :active_packages_count, 
             :delivered_packages_count,
             
             # Accessibility and areas
             :accessible_areas, :accessible_locations,
             
             # Timestamps
             :created_at, :updated_at, :last_seen_at, :confirmed_at

  # ===========================================
  # 🔐 AUTHENTICATION & SECURITY ATTRIBUTES
  # ===========================================

  def google_user
    safe_call(:google_user?) || false
  end

  def needs_password
    safe_call(:needs_password?) || false
  end

  def provider
    safe_call(:provider)
  end

  def confirmed
    object.respond_to?(:confirmed_at) && object.confirmed_at.present?
  end

  def is_active
    safe_call(:active?) || false
  end

  def online
    safe_call(:online) || false
  end

  def account_status
    return 'locked' if safe_call(:access_locked?)
    return 'unconfirmed' unless confirmed
    return 'active' if is_active
    'inactive'
  end

  def google_image_url
    # Return Google image URL only if user doesn't have uploaded avatar
    return nil if object.avatar&.attached?
    safe_call(:google_image_url)
  end

  # ===========================================
  # 👤 PROFILE & DISPLAY ATTRIBUTES
  # ===========================================

  def roles
    begin
      object.roles.pluck(:name)
    rescue => e
      Rails.logger.error "Error fetching user roles: #{e.message}"
      []
    end
  end

  def primary_role
    safe_call(:primary_role) || 'client'
  end

  def role_display
    safe_call(:role_display_name) || primary_role.humanize
  end

  def role_description
    safe_call(:role_description) || 'System user'
  end

  def available_actions
    safe_call(:available_actions) || []
  end

  def full_name
    safe_call(:full_name) || "#{first_name} #{last_name}".strip
  end

  def display_name
    safe_call(:display_name) || full_name.presence || email&.split('@')&.first || 'User'
  end

  def initials
    safe_call(:initials) || begin
      name_parts = [first_name, last_name].compact
      name_parts.map(&:first).join.upcase if name_parts.any?
    end
  end

  def profile_complete
    first_name.present? && 
    last_name.present? && 
    phone_number.present?
  end

  # ===========================================
  # 🎨 AVATAR HANDLING (Enhanced with Google support)
  # ===========================================

  # ===========================================
# 🎨 AVATAR HANDLING (Delegates to AvatarHelper)
# ===========================================

def avatar_url
  # If uploaded avatar exists, use helper logic (ensures CDN/R2 URL)
  return avatar_api_url(object) if object.avatar&.attached?
  
  # Fallback: Google avatar if no uploaded avatar
  google_avatar_url
end


  private

  def uploaded_avatar_url
    return nil unless object.avatar&.attached?

    begin
      avatar_blob = object.avatar.blob
      return nil unless avatar_blob&.persisted?
      
      # Additional safety check - ensure the attachment is properly linked
      return nil unless object.avatar.attachment&.persisted?
      
      host = first_available_host
      return nil unless host

      # Generate URL with error handling
      rails_blob_url(
        object.avatar, 
        host: host, 
        protocol: host.include?('https') ? 'https' : 'http'
      )
      
    rescue ActiveStorage::FileNotFoundError => e
      Rails.logger.warn "Avatar file not found for user #{object.id}: #{e.message}"
      nil
    rescue NoMethodError => e
      Rails.logger.warn "Avatar method error for user #{object.id}: #{e.message}"
      nil
    rescue => e
      Rails.logger.error "Error generating avatar URL for user #{object.id}: #{e.message}"
      nil
    end
  end

  def google_avatar_url
    # Fallback to Google avatar if no uploaded avatar
    return nil if uploaded_avatar_url.present?
    safe_call(:google_image_url)
  end

  public

  # ===========================================
  # 📦 PACKAGE DELIVERY PERMISSIONS
  # ===========================================

  def can_scan_packages
    safe_call(:can_scan_packages?) || false
  end

  def can_print_labels
    safe_call(:can_print_labels?) || false
  end

  def can_manage_packages
    safe_call(:can_manage_packages?) || false
  end

  def can_view_all_packages
    safe_call(:can_view_all_packages?) || false
  end

  # ===========================================
  # 📊 PACKAGE STATISTICS
  # ===========================================

  def pending_packages_count
    safe_call(:pending_packages_count) || 0
  end

  def active_packages_count
    safe_call(:active_packages_count) || 0
  end

  def delivered_packages_count
    safe_call(:delivered_packages_count) || 0
  end

  # ===========================================
  # 📍 LOCATION & ACCESSIBILITY
  # ===========================================

  def accessible_areas
    safe_call(:accessible_areas) || []
  end

  def accessible_locations
    safe_call(:accessible_locations) || []
  end

  # ===========================================
  # 📱 BACKWARD COMPATIBILITY METHODS
  # ===========================================

  def first_name
    safe_call(:first_name)
  end

  def last_name
    safe_call(:last_name)
  end

  def username
    safe_call(:username)
  end

  def phone
    safe_call(:phone) || phone_number
  end

  def phone_number
    safe_call(:phone_number)
  end

  # ===========================================
  # 🕒 TIMESTAMP ATTRIBUTES
  # ===========================================

  def created_at
    object.created_at
  end

  def updated_at
    object.updated_at
  end

  def last_seen_at
    safe_call(:last_seen_at)
  end

  def confirmed_at
    safe_call(:confirmed_at)
  end

  # ===========================================
  # 🛡️ CONDITIONAL ATTRIBUTES (Advanced Usage)
  # ===========================================

  # Include scanning stats only for staff users
  attribute :daily_scanning_stats, if: :staff_user?
  attribute :performance_metrics, if: :staff_user?

  # Include role-specific details for admin/management
  attribute :role_records, if: :admin_or_management?

  # Include sensitive info only when explicitly requested
  attribute :has_password, if: :include_sensitive_info?

  def daily_scanning_stats
    return {} unless staff_user?
    safe_call(:daily_scanning_stats) || {}
  end

  def performance_metrics
    return {} unless staff_user?
    safe_call(:performance_metrics, 1.month) || {}
  end

  def role_records
    return {} unless admin_or_management?
    
    begin
      result = {}
      
      if object.respond_to?(:agents) && object.agents.any?
        result[:agents] = object.agents.includes(:area).map do |agent|
          {
            id: agent.id,
            area: agent.area&.name,
            active: agent.active?
          }
        end
      end
      
      if object.respond_to?(:riders) && object.riders.any?
        result[:riders] = object.riders.includes(:area).map do |rider|
          {
            id: rider.id,
            area: rider.area&.name,
            active: rider.active?
          }
        end
      end
      
      if object.respond_to?(:warehouse_staff) && object.warehouse_staff.any?
        result[:warehouse_staff] = object.warehouse_staff.includes(:location).map do |staff|
          {
            id: staff.id,
            location: staff.location&.name,
            active: staff.active?
          }
        end
      end
      
      result
    rescue => e
      Rails.logger.error "Error fetching role records for user #{object.id}: #{e.message}"
      {}
    end
  end

  def has_password
    return false unless include_sensitive_info?
    object.respond_to?(:encrypted_password) && object.encrypted_password.present?
  end

  # ===========================================
  # 🔧 CONDITIONAL LOGIC HELPERS
  # ===========================================

  def staff_user?
    safe_call(:staff?) || false
  end

  def admin_or_management?
    safe_call(:admin?) || 
    safe_call(:has_role?, :warehouse) || 
    safe_call(:has_role?, :support) || 
    false
  end

  def include_sensitive_info?
    # Check if sensitive info should be included based on context
    # This could be set by the controller when calling the serializer
    instance_options[:include_sensitive_info] == true
  end

  # ===========================================
  # 🛠️ UTILITY METHODS
  # ===========================================

  # Safe method calling with error handling
  def safe_call(method_name, *args)
    return nil unless object.respond_to?(method_name)
    
    begin
      object.public_send(method_name, *args)
    rescue => e
      Rails.logger.error "Error calling #{method_name} on user #{object.id}: #{e.message}"
      nil
    end
  end

  # ===========================================
  # 🎯 CONTEXT-SPECIFIC SERIALIZATION
  # ===========================================

  # You can use this in your controller to include additional context:
  # UserSerializer.new(user, include_sensitive_info: true, context: 'admin_panel')
  
  def context
    instance_options[:context]
  end

  # Add context-specific attributes
  attribute :admin_notes, if: :admin_context?
  attribute :security_logs, if: :security_context?

  def admin_context?
    context == 'admin_panel' || context == 'user_management'
  end

  def security_context?
    context == 'security_audit' || context == 'admin_panel'
  end

  def admin_notes
    return nil unless admin_context?
    # Return admin-specific notes if available
    safe_call(:admin_notes)
  end

  def security_logs
    return [] unless security_context?
    # Return recent security events if available
    []
  end
end