# app/controllers/application_controller.rb
# Fixed for API-only Rails with JWT + OAuth authentication

class ApplicationController < ActionController::API
  include ActionController::MimeResponds
  
  # ===========================================
  # 🔐 AUTHENTICATION CONFIGURATION
  # ===========================================
  
  # Authentication (devise-jwt handles JWT automatically)
  before_action :authenticate_user!, unless: :skip_authentication?
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :log_user_activity, if: :user_signed_in?
  
  # Error handling
  rescue_from ActiveRecord::RecordNotFound, with: :not_found_response
  rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity_response
  rescue_from Pundit::NotAuthorizedError, with: :unauthorized_response if defined?(Pundit)

  # ===========================================
  # 🔐 AUTHENTICATION LOGIC (FIXED)
  # ===========================================

  def authenticate_user!
    # Skip authentication for routes that don't need it
    return if skip_authentication?
    
    # Skip for OAuth routes - they handle their own auth flow
    return if oauth_route?
    
    # Skip for public/health endpoints
    return if public_endpoint?
    
    # Let devise-jwt handle the rest
    super
  end

  private

  # ===========================================
  # 🚦 ROUTE CLASSIFICATION METHODS
  # ===========================================

  # Check if authentication should be skipped entirely
  def skip_authentication?
    public_endpoint? || oauth_route? || health_check_route? || webhook_route?
  end

  # Check if this is an OAuth related route
  def oauth_route?
    oauth_patterns = [
      %r{^/api/v1/auth/google},           # Google OAuth endpoints
      %r{^/api/v1/auth/failure},          # OAuth failure
      %r{^/auth/},                        # Legacy OAuth routes
      %r{^/users/auth/}                   # Devise OAuth routes
    ]
    
    oauth_patterns.any? { |pattern| request.path.match?(pattern) }
  end

  # Check if this is a public endpoint
  def public_endpoint?
    public_patterns = [
      %r{^/public/},                      # Public tracking pages
      %r{^/api/v1/ping$},                 # API health check
      %r{^/api/v1/status$},               # API status
      %r{^/api/v1/track/}                 # Public package tracking
    ]
    
    public_patterns.any? { |pattern| request.path.match?(pattern) }
  end

  # Check if this is a health check route
  def health_check_route?
    health_patterns = [
      %r{^/up$},                          # Rails health check
      %r{^/health},                       # Custom health checks
      %r{^/rails/health}                  # Rails health endpoint
    ]
    
    health_patterns.any? { |pattern| request.path.match?(pattern) }
  end

  # Check if this is a webhook route
  def webhook_route?
    request.path.start_with?('/webhooks/')
  end

  # ===========================================
  # 👤 USER HELPER METHODS
  # ===========================================

  # Get current user's primary role
  def current_user_role
    return nil unless current_user
    current_user.primary_role
  end

  # Check if current user has specific role
  def current_user_has_role?(role)
    return false unless current_user
    current_user.has_role?(role.to_sym)
  end

  # Check if current user can access specific resource
  def can_access_resource?(resource)
    return false unless current_user
    return true if current_user.admin?
    
    case resource.class.name
    when 'Package'
      current_user.can_access_package?(resource)
    else
      false
    end
  end

  # ===========================================
  # 🔐 GOOGLE OAUTH HELPERS
  # ===========================================

  # Check if current user is a Google OAuth user
  def google_oauth_user?
    current_user&.google_user?
  end

  # Check if user needs to complete profile setup
  def needs_profile_setup?
    return false unless current_user
    
    current_user.google_user? && (
      current_user.first_name.blank? ||
      current_user.last_name.blank? ||
      current_user.phone_number.blank?
    )
  end

  # ===========================================
  # 🚫 ERROR HANDLING METHODS
  # ===========================================

  # Handle not found errors
  def not_found_response(exception)
    Rails.logger.error "Not found: #{exception.message}"
    
    render json: {
      status: 'error',
      message: 'Resource not found',
      code: 'not_found'
    }, status: :not_found
  end

  # Handle validation errors
  def unprocessable_entity_response(exception)
    Rails.logger.error "Validation error: #{exception.message}"
    
    render json: {
      status: 'error',
      message: 'Validation failed',
      errors: exception.record&.errors&.full_messages || [exception.message],
      code: 'validation_failed'
    }, status: :unprocessable_entity
  end

  # Handle authorization errors (Pundit)
  def unauthorized_response(exception)
    Rails.logger.error "Authorization error: #{exception.message}"
    
    render json: {
      status: 'error',
      message: 'Not authorized to perform this action',
      code: 'not_authorized'
    }, status: :forbidden
  end

  # Handle route not found
  def route_not_found
    render json: {
      status: 'error',
      message: 'Route not found',
      code: 'route_not_found'
    }, status: :not_found
  end

  # ===========================================
  # 🔧 DEVISE CONFIGURATION
  # ===========================================

  # Configure permitted parameters for Devise
  def configure_permitted_parameters
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

  # Log user activity
  def log_user_activity
    return unless current_user && user_signed_in?
    
    # Update last seen timestamp
    if current_user.respond_to?(:last_seen_at) && 
       (current_user.last_seen_at.nil? || current_user.last_seen_at < 5.minutes.ago)
      current_user.update_column(:last_seen_at, Time.current)
    end
    
    # Mark user as online
    current_user.mark_online! if current_user.respond_to?(:mark_online!)
    
    # Optional: Log the activity for analytics (only in development)
    if Rails.env.development?
      Rails.logger.debug "User activity: #{current_user.email} - #{request.method} #{request.path}"
    end
  end

  # ===========================================
  # 📱 API RESPONSE HELPERS
  # ===========================================

  # Standard success response
  def success_response(data = {}, message = 'Success', status = :ok)
    render json: {
      status: 'success',
      message: message,
      **data
    }, status: status
  end

  # Standard error response
  def error_response(message, code = 'error', status = :bad_request, details = {})
    render json: {
      status: 'error',
      message: message,
      code: code,
      **details
    }, status: status
  end

  # Paginated response helper
  def paginated_response(collection, serializer_class = nil, meta = {})
    if defined?(Kaminari) && collection.respond_to?(:current_page)
      # Using Kaminari pagination
      pagination_meta = {
        current_page: collection.current_page,
        per_page: collection.limit_value,
        total_pages: collection.total_pages,
        total_count: collection.total_count
      }
    else
      pagination_meta = {}
    end

    data = if serializer_class
      collection.map { |item| serializer_class.new(item).as_json }
    else
      collection.as_json
    end

    render json: {
      status: 'success',
      data: data,
      meta: pagination_meta.merge(meta)
    }
  end

  # ===========================================
  # 🎯 ROLE-BASED ACCESS CONTROL (SAFE)
  # ===========================================

  # Ensure user has required role (safe - won't trigger auth for public endpoints)
  def ensure_role!(required_role)
    return true if skip_authentication? # Skip role checks for public endpoints
    
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

  # Ensure user is admin (safe)
  def ensure_admin!
    ensure_role!(:admin)
  end

  # Ensure user is staff (safe)
  def ensure_staff!
    return true if skip_authentication? # Skip for public endpoints
    
    unless current_user.present? && current_user.staff?
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

  # Log security events
  def log_security_event(event_type, details = {})
    Rails.logger.warn "Security event: #{event_type} - User: #{current_user&.email} - IP: #{request.remote_ip} - Details: #{details}"
  end

  # Basic security checks
  def security_check
    # Add security checks here:
    # - Rate limiting
    # - IP allowlisting  
    # - Suspicious pattern detection
    true
  end

  # ===========================================
  # 🔧 DEVISE OVERRIDES (for API)
  # ===========================================

  protected

  # Override Devise's after_sign_in_path_for (for API, return nil)
  def after_sign_in_path_for(resource)
    # For API requests, don't redirect
    return nil if request.format.json?
    
    # Role-based redirect for web requests (if you have web interface)
    case resource.primary_role
    when 'admin'
      '/admin/dashboard'
    when 'agent'
      '/agent/dashboard'
    when 'rider'
      '/rider/dashboard'
    when 'warehouse'
      '/warehouse/dashboard'
    when 'support'
      '/support/dashboard'
    else
      '/dashboard'
    end
  end

  # Override Devise's after_sign_out_path_for (for API, return nil)
  def after_sign_out_path_for(resource_or_scope)
    return nil if request.format.json?
    '/login'
  end

  # Override respond_with for API responses
  def respond_with(resource, _opts = {})
    # This method is called by Devise controllers
    # Since we're using API-only, we typically handle responses manually in controllers
  end

  # Override respond_to_on_destroy for logout
  def respond_to_on_destroy
    # This would be handled in your sessions controller
  end
end