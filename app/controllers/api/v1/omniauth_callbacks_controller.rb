# app/controllers/api/v1/omniauth_callbacks_controller.rb

class Api::V1::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  respond_to :json
  protect_from_forgery with: :null_session
  skip_before_action :verify_authenticity_token

  # ===========================================
  # 🔐 GOOGLE OAUTH CALLBACK HANDLER
  # ===========================================

  def google_oauth2
    Rails.logger.info "Google OAuth2 callback received"
    Rails.logger.info "Auth hash: #{request.env['omniauth.auth']&.info&.email}"

    begin
      # Get the auth hash from omniauth
      auth_hash = request.env['omniauth.auth']
      
      unless auth_hash
        Rails.logger.error "No auth hash found in callback"
        handle_auth_failure('No authentication data received')
        return
      end

      # Find or create user from Google OAuth
      @user = User.from_omniauth(auth_hash)
      
      if @user.persisted?
        # User successfully created/found
        sign_in(@user)
        @user.mark_online!
        
        Rails.logger.info "Successfully signed in user: #{@user.email}"
        
        # Generate JWT token for API access
        token = User.generate_google_oauth_token(@user)
        
        # Return JSON response for API clients
        if request.format.json? || request.headers['Accept']&.include?('application/json')
          render json: {
            status: 'success',
            message: 'Successfully authenticated with Google',
            user: serialize_user(@user),
            token: token,
            token_type: 'Bearer',
            auth_method: 'google_oauth2',
            redirect_url: determine_redirect_url
          }, status: :ok
        else
          # Redirect for web clients
          redirect_to determine_redirect_url, notice: 'Successfully signed in with Google!'
        end
        
      else
        # User creation failed
        Rails.logger.error "User creation failed: #{@user.errors.full_messages}"
        handle_auth_failure("Account creation failed: #{@user.errors.full_messages.join(', ')}")
      end

    rescue => e
      Rails.logger.error "Google OAuth callback error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      handle_auth_failure("Authentication error: #{e.message}")
    end
  end

  # ===========================================
  # 🚫 OAUTH FAILURE HANDLER
  # ===========================================

  def failure
    error_kind = params[:error_reason] || 'unknown'
    error_message = params[:error_description] || 'Authentication failed'
    
    Rails.logger.error "OAuth failure: #{error_kind} - #{error_message}"
    
    if request.format.json? || request.headers['Accept']&.include?('application/json')
      render json: {
        status: 'error',
        message: 'Google authentication failed',
        error: error_kind,
        description: error_message,
        code: 'oauth_failure'
      }, status: :bad_request
    else
      # Redirect for web clients
      redirect_to failure_redirect_url, alert: "Authentication failed: #{error_message}"
    end
  end

  private

  # ===========================================
  # 🔧 HELPER METHODS
  # ===========================================

  # Handle authentication failures
  def handle_auth_failure(message)
    Rails.logger.error "Auth failure: #{message}"
    
    if request.format.json? || request.headers['Accept']&.include?('application/json')
      render json: {
        status: 'error',
        message: message,
        code: 'authentication_failed'
      }, status: :unprocessable_entity
    else
      redirect_to failure_redirect_url, alert: message
    end
  end

  # Determine where to redirect after successful auth
  def determine_redirect_url
    # Check for stored location or use default
    stored_location = stored_location_for(:user)
    return stored_location if stored_location.present?
    
    # Role-based redirect
    case @user.primary_role
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
      '/dashboard' # Default for clients
    end
  end

  # Determine where to redirect on failure
  def failure_redirect_url
    '/login?error=oauth_failed'
  end

  # Serialize user for JSON response
  def serialize_user(user)
    user.as_json(
      include_role_details: true,
      include_stats: false
    ).tap do |json|
      # Add additional fields for OAuth response
      json.merge!(
        'google_user' => user.google_user?,
        'needs_password' => user.needs_password?,
        'profile_complete' => profile_complete?(user),
        'setup_required' => setup_required?(user)
      )
    end
  end

  # Check if user profile is complete
  def profile_complete?(user)
    user.first_name.present? && 
    user.last_name.present? && 
    user.phone_number.present?
  end

  # Check if additional setup is required
  def setup_required?(user)
    # New Google users might need additional setup
    return false unless user.google_user?
    
    # Check if user needs to complete profile
    !profile_complete?(user) || 
    # Check if user needs to set password for non-Google login
    (user.needs_password? && user.created_at > 1.hour.ago)
  end

  # ===========================================
  # 🔧 DEVISE OVERRIDES
  # ===========================================

  # Override to prevent automatic redirect
  def after_omniauth_failure_path_for(scope)
    failure_redirect_url
  end

  # Override to handle different response formats
  def after_sign_in_path_for(resource)
    determine_redirect_url
  end
end