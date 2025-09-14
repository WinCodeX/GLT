# app/controllers/application_controller.rb - Fixed for pure JWT authentication
class ApplicationController < ActionController::API
  include ActionController::MimeResponds
  
  # ===========================================
  # 🔐 JWT AUTHENTICATION (FIXED - NO SESSION INTERFERENCE)
  # ===========================================
  
  before_action :authenticate_user_via_jwt!, unless: :skip_authentication?
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :log_user_activity, if: :user_signed_in?
  
  # Error handling
  rescue_from ActiveRecord::RecordNotFound, with: :not_found_response
  rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity_response
  rescue_from CanCan::AccessDenied, with: :forbidden_response if defined?(CanCan)

  # ===========================================
  # 🔐 PURE JWT AUTHENTICATION (NO DEVISE INTERFERENCE)
  # ===========================================

  def authenticate_user_via_jwt!
    # Skip authentication for routes that don't need it
    return if skip_authentication?
    
    # Extract JWT token from Authorization header
    token = extract_jwt_token
    
    unless token.present?
      render_unauthorized('Missing authentication token')
      return
    end

    begin
      # Decode JWT token directly (no Devise session checks)
      decoded_token = JWT.decode(
        token, 
        jwt_secret_key, 
        true, 
        { algorithm: 'HS256' }
      )
      
      user_data = decoded_token.first
      @current_user = User.find_by(id: user_data['sub'])
      
      unless @current_user.present?
        Rails.logger.warn "JWT token valid but user not found: #{user_data['sub']}"
        render_unauthorized('User not found')
        return
      end
      
      Rails.logger.info "JWT authenticated user: #{@current_user.email}"
      
    rescue JWT::DecodeError => e
      Rails.logger.warn "JWT decode error: #{e.message}"
      render_unauthorized('Invalid token')
      return
    rescue JWT::ExpiredSignature
      # This shouldn't happen since our tokens don't expire, but handle it anyway
      Rails.logger.warn "JWT token expired"
      render_unauthorized('Token expired')
      return
    rescue => e
      Rails.logger.error "JWT authentication error: #{e.message}"
      render_unauthorized('Authentication failed')
      return
    end
  end

  # Override Devise methods for JWT compatibility
  def current_user
    @current_user
  end

  def user_signed_in?
    current_user.present?
  end

  private

  # ===========================================
  # 🔧 JWT HELPER METHODS
  # ===========================================

  def extract_jwt_token
    auth_header = request.headers['Authorization']
    return nil unless auth_header.present?
    
    # Extract token from "Bearer TOKEN" format
    auth_header.split(' ').last if auth_header.start_with?('Bearer ')
  end

  def jwt_secret_key
    ENV['DEVISE_JWT_SECRET_KEY'] || 
    Rails.application.credentials.jwt_secret_key || 
    Rails.application.secret_key_base
  end

  def render_unauthorized(message = 'Unauthorized')
    render json: { 
      status: 'error', 
      message: message,
      code: 'unauthorized'
    }, status: :unauthorized
  end

  # ===========================================
  # 🚦 AUTHENTICATION SKIP CONDITIONS
  # ===========================================

  def skip_authentication?
    public_endpoint? || oauth_route? || health_check_route?
  end

  def public_endpoint?
    public_patterns = [
      %r{^/api/v1/ping$},                 # API health check
      %r{^/api/v1/status$},               # API status  
      %r{^/api/v1/track/},                # Public package tracking
      %r{^/public/}                       # Public endpoints
    ]
    
    public_patterns.any? { |pattern| request.path.match?(pattern) }
  end

  def oauth_route?
    oauth_patterns = [
      %r{^/api/v1/login$},                # Login endpoint
      %r{^/api/v1/signup$},               # Signup endpoint
      %r{^/api/v1/sessions$},             # Sessions endpoint (POST for create)
      %r{^/api/v1/google_login$},         # Google login
      %r{^/api/v1/auth/google},           # Google OAuth endpoints
      %r{^/api/v1/auth/failure},          # OAuth failure
      %r{^/users/auth/}                   # Devise OAuth routes
    ]
    
    oauth_patterns.any? { |pattern| request.path.match?(pattern) }
  end

  def health_check_route?
    health_patterns = [
      %r{^/up$},                          # Rails health check
      %r{^/health},                       # Custom health checks
      %r{^/rails/health}                  # Rails health endpoint
    ]
    
    health_patterns.any? { |pattern| request.path.match?(pattern) }
  end

  # ===========================================
  # 👤 USER HELPER METHODS
  # ===========================================

  def current_user_role
    return nil unless current_user
    current_user.primary_role
  end

  def current_user_has_role?(role)
    return false unless current_user
    current_user.has_role?(role.to_sym)
  end

  def can_access_resource?(resource)
    return false unless current_user
    return true if current_user_has_role?(:admin)
    
    case resource.class.name
    when 'Package'
      current_user.can_access_package?(resource) if current_user.respond_to?(:can_access_package?)
    else
      false
    end
  end

  # ===========================================
  # 🚫 ERROR HANDLING METHODS
  # ===========================================

  def not_found_response(exception)
    Rails.logger.error "Not found: #{exception.message}"
    
    render json: {
      status: 'error',
      message: 'Resource not found',
      code: 'not_found'
    }, status: :not_found
  end

  def unprocessable_entity_response(exception)
    Rails.logger.error "Validation error: #{exception.message}"
    
    render json: {
      status: 'error',
      message: 'Validation failed',
      errors: exception.record&.errors&.full_messages || [exception.message],
      code: 'validation_failed'
    }, status: :unprocessable_entity
  end

  def forbidden_response(exception)
    Rails.logger.error "Access forbidden: #{exception.message}"
    
    render json: {
      status: 'error',
      message: 'Access forbidden',
      code: 'forbidden'
    }, status: :forbidden
  end

  # ===========================================
  # 🔧 DEVISE CONFIGURATION
  # ===========================================

  def configure_permitted_parameters
    return unless devise_parameter_sanitizer.present?
    
    devise_parameter_sanitizer.permit(:sign_up, keys: [
      :first_name, :last_name, :phone_number
    ])
    
    devise_parameter_sanitizer.permit(:account_update, keys: [
      :first_name, :last_name, :phone_number
    ])
  end

  # ===========================================
  # 📊 ACTIVITY LOGGING
  # ===========================================

  def log_user_activity
    return unless current_user.present?
    
    # Update last seen timestamp (avoid frequent database writes)
    if current_user.respond_to?(:last_seen_at) && 
       (current_user.last_seen_at.nil? || current_user.last_seen_at < 5.minutes.ago)
      current_user.update_column(:last_seen_at, Time.current)
    end
    
    # Mark user as online
    current_user.mark_online! if current_user.respond_to?(:mark_online!)
  end

  # ===========================================
  # 📱 API RESPONSE HELPERS
  # ===========================================

  def success_response(data = {}, message = 'Success', status = :ok)
    render json: {
      status: 'success',
      message: message,
      **data
    }, status: status
  end

  def error_response(message, code = 'error', status = :bad_request, details = {})
    render json: {
      status: 'error',
      message: message,
      code: code,
      **details
    }, status: status
  end

  # ===========================================
  # 🎯 ROLE-BASED ACCESS CONTROL
  # ===========================================

  def ensure_role!(required_role)
    return true if skip_authentication?
    
    unless current_user.present? && current_user_has_role?(required_role)
      error_response(
        "Access denied. #{required_role.to_s.humanize} role required.",
        'insufficient_role',
        :forbidden
      )
      return false
    end
    true
  end

  def ensure_admin!
    ensure_role!(:admin) || ensure_role!(:super_admin)
  end

  def ensure_staff!
    return true if skip_authentication?
    
    staff_roles = [:admin, :super_admin, :agent, :warehouse, :support]
    has_staff_role = staff_roles.any? { |role| current_user_has_role?(role) }
    
    unless current_user.present? && has_staff_role
      error_response(
        'Access denied. Staff role required.',
        'staff_access_required',
        :forbidden
      )
      return false
    end
    true
  end

  # ===========================================
  # 🔒 SECURITY METHODS
  # ===========================================

  def log_security_event(event_type, details = {})
    Rails.logger.warn "Security event: #{event_type} - User: #{current_user&.email} - IP: #{request.remote_ip} - Details: #{details}"
  end

  # ===========================================
  # 🔧 UTILITY METHODS
  # ===========================================

  def google_oauth_user?
    current_user&.google_user?
  end

  def needs_profile_setup?
    return false unless current_user
    
    current_user.google_user? && (
      current_user.first_name.blank? ||
      current_user.last_name.blank? ||
      current_user.phone_number.blank?
    )
  end

  # Get current user's primary role safely
  def user_role
    current_user&.primary_role
  end

  # Check if current user is admin
  def admin?
    current_user_has_role?(:admin) || current_user_has_role?(:super_admin)
  end

  # Check if current user is staff (any staff role)
  def staff?
    return false unless current_user
    
    staff_roles = [:admin, :super_admin, :agent, :warehouse, :support]
    staff_roles.any? { |role| current_user_has_role?(role) }
  end
end