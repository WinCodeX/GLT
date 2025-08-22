# app/controllers/application_controller.rb - Simplified for devise-jwt

class ApplicationController < ActionController::API
  include ActionController::MimeResponds
  
  # Authentication (devise-jwt handles JWT automatically)
  before_action :authenticate_user!
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :log_user_activity, if: :user_signed_in?
  
  # CORS and security
  protect_from_forgery with: :null_session, if: Proc.new { |c| c.request.format == 'application/json' }
  
  # Error handling
  rescue_from ActiveRecord::RecordNotFound, with: :not_found_response
  rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity_response
  rescue_from Pundit::NotAuthorizedError, with: :unauthorized_response if defined?(Pundit)

  # ===========================================
  # 🔐 AUTHENTICATION OVERRIDE (for public endpoints)
  # ===========================================

  def authenticate_user!
    # Skip authentication for public endpoints
    return if skip_authentication?
    
    # Let devise-jwt handle the rest
    super
  end

  private

  # Check if authentication should be skipped
  def skip_authentication?
    # Public endpoints that don't require authentication
    public_endpoints = [
      '/api/v1/ping',
      '/api/v1/health', 
      '/api/v1/status',
      '/up',
      '/health'
    ]
    
    # Skip for public tracking
    return true if request.path.start_with?('/public/')
    
    # Skip for OAuth callbacks (they have their own auth flow)
    return true if request.path.include?('/auth/')
    
    # Skip for webhooks (they should use different auth like API keys)
    return true if request.path.start_with?('/webhooks/')
    
    # Check against public endpoints
    public_endpoints.any? { |path| request.path.start_with?(path) }
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
    
    # Add resource-specific access logic here
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
  # 🌐 CORS METHODS (if needed)
  # ===========================================

  # Set CORS headers
  def set_cors_headers
    headers['Access-Control-Allow-Origin'] = '*'
    headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, PATCH, DELETE, OPTIONS'
    headers['Access-Control-Allow-Headers'] = 'Origin, Content-Type, Accept, Authorization, Token'
    headers['Access-Control-Max-Age'] = '1728000'
  end

  # Handle preflight requests
  def cors_preflight_check
    if request.method == 'OPTIONS'
      set_cors_headers
      render plain: '', status: :ok
    end
  end

  # ===========================================
  # 📊 ACTIVITY LOGGING
  # ===========================================

  # Log user activity
  def log_user_activity
    return unless current_user && user_signed_in?
    
    # Update last seen timestamp
    current_user.update_column(:last_seen_at, Time.current) if current_user.respond_to?(:last_seen_at)
    
    # Mark user as online
    current_user.mark_online! if current_user.respond_to?(:mark_online!)
    
    # Optional: Log the activity for analytics
    Rails.logger.debug "User activity: #{current_user.email} - #{request.method} #{request.path}"
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
  # 🎯 ROLE-BASED ACCESS CONTROL
  # ===========================================

  # Ensure user has required role
  def ensure_role!(required_role)
    unless current_user_has_role?(required_role)
      error_response(
        "Access denied. #{required_role.to_s.humanize} role required.",
        'insufficient_role',
        :forbidden
      )
      return false
    end
    true
  end

  # Ensure user is admin
  def ensure_admin!
    ensure_role!(:admin)
  end

  # Ensure user is staff (agent, rider, warehouse, or admin)
  def ensure_staff!
    unless current_user&.staff?
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

  # Override Devise's respond_with for API responses
  def respond_with(resource, _opts = {})
    # This method is called by Devise controllers
    # Since we're using API-only, we typically handle responses manually in controllers
  end

  # Override respond_to_on_destroy for logout
  def respond_to_on_destroy
    # This would be handled in your sessions controller
  end
end