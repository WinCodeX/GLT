# config/initializers/devise.rb - Fixed for API-only JWT (no session interference)

Devise.setup do |config|
  # ===========================================
  # 🔧 BASIC DEVISE CONFIGURATION
  # ===========================================
  
  config.mailer_sender = 'noreply@gltlogistics.co.ke'
  
  # ==> ORM configuration
  require 'devise/orm/active_record'

  # ==> Basic Authentication Configuration
  config.case_insensitive_keys = [:email]
  config.strip_whitespace_keys = [:email]
  
  # ===========================================
  # 📱 API-ONLY CONFIGURATION (FIXED)
  # ===========================================
  
  # FIXED: Skip session storage completely for API-only mode
  config.skip_session_storage = [:http_auth, :params_auth, :token_auth]
  
  # FIXED: No navigational formats for API-only
  config.navigational_formats = []
  
  # Response format
  config.responder.error_status = :unprocessable_entity
  config.responder.redirect_status = :see_other

  # ==> Password Configuration
  config.password_length = 8..128
  config.email_regexp = /\A[^@\s]+@[^@\s]+\z/
  
  # Use bcrypt with appropriate cost
  config.stretches = Rails.env.test? ? 1 : 12

  # ===========================================
  # ⚠️ CRITICAL FIX: REMOVE SESSION TIMEOUT FOR JWT API
  # ===========================================
  
  # FIXED: Do NOT set timeout_in for API-only JWT mode
  # This was causing JWT tokens to be treated as expired after 24 hours
  # config.timeout_in = 24.hours  # ❌ REMOVED - This interfered with JWT
  
  # ==> Account Locking Configuration
  config.lock_strategy = :failed_attempts
  config.unlock_strategy = :both
  config.maximum_attempts = 5
  config.unlock_in = 1.hour
  config.last_attempt_warning = true
  config.reset_password_within = 6.hours

  # ==> Confirmation Configuration (DISABLED for API)
  # FIXED: Disable email confirmation for API-only mode
  # config.allow_unconfirmed_access_for = 0.days
  # config.confirm_within = 3.days
  # config.reconfirmable = true

  # ==> Rememberable Configuration (DISABLED for JWT API)
  # FIXED: Disable rememberable for JWT API mode
  # config.expire_all_remember_me_on_sign_out = true
  # config.rememberable_options = {}

  # ==> Security Configuration
  config.paranoid = true
  config.sign_out_all_scopes = false  # FIXED: Allow single-scope signout for API
  config.sign_in_after_change_password = false  # FIXED: API doesn't auto sign-in
  config.sign_out_via = [:delete, :post]  # Allow both for API flexibility

  # ===========================================
  # 🔐 JWT CONFIGURATION (FIXED - PURE JWT MODE)
  # ===========================================
  
  config.jwt do |jwt|
    # Use environment variable or Rails credentials for JWT secret
    jwt.secret = ENV['DEVISE_JWT_SECRET_KEY'] || 
                 Rails.application.credentials.jwt_secret_key || 
                 Rails.application.secret_key_base

    # FIXED: JWT dispatch routes for API endpoints
    jwt.dispatch_requests = [
      ['POST', %r{^/api/v1/login$}],
      ['POST', %r{^/api/v1/signup$}],
      ['POST', %r{^/api/v1/sessions$}],
      ['POST', %r{^/api/v1/auth/google_login$}],
      ['POST', %r{^/api/v1/auth/google_oauth2/callback$}]
    ]
    
    # FIXED: JWT revocation routes
    jwt.revocation_requests = [
      ['DELETE', %r{^/api/v1/logout$}],
      ['POST', %r{^/api/v1/logout$}],
      ['DELETE', %r{^/api/v1/sessions$}]
    ]
    
    # 🔥 CRITICAL FIX: JWT tokens should NEVER expire
    jwt.expiration_time = nil  # No expiration - tokens are permanent until revoked
    jwt.algorithm = 'HS256'
  end

  # ===========================================
  # 🔐 GOOGLE OAUTH CONFIGURATION (FIXED)
  # ===========================================
  
  config.omniauth :google_oauth2,
                  ENV['GOOGLE_CLIENT_ID'] || Rails.application.credentials.dig(:google_oauth, :client_id),
                  ENV['GOOGLE_CLIENT_SECRET'] || Rails.application.credentials.dig(:google_oauth, :client_secret),
                  {
                    # OAuth scope & permissions
                    scope: 'email,profile',
                    prompt: 'select_account',
                    access_type: 'offline',
                    
                    # FIXED: API-specific OAuth settings
                    skip_jwt: false,  # Allow JWT generation from OAuth
                    
                    # FIXED: Callback configuration for API
                    callback_path: '/api/v1/auth/google_oauth2/callback',
                    
                    # Security settings
                    provider_ignores_state: false,
                    
                    # UI customization
                    image_aspect_ratio: 'square',
                    image_size: 150,
                    
                    # Client options
                    client_options: {
                      ssl: { 
                        verify: Rails.env.production? 
                      }
                    }
                  }

  # ===========================================
  # 🧪 DEVELOPMENT/TEST CONFIGURATION
  # ===========================================
  
  if Rails.env.development? || Rails.env.test?
    # Reduce password stretches for faster tests
    config.stretches = 1 if Rails.env.test?
    
    # Development settings
    if Rails.env.development?
      # Allow unconfirmed access in development
      # config.allow_unconfirmed_access_for = 30.days
      
      # Disable sending emails in development
      config.mailer = 'DeviseMailer'
    end
  end

  # ===========================================
  # 🔍 LOGGING AND DEBUGGING
  # ===========================================
  
  Rails.application.config.after_initialize do
    if defined?(Devise)
      Rails.logger.info "✅ Devise initialized for API-only JWT mode"
      
      # Check if JWT is available
      if defined?(Devise::JWT)
        Rails.logger.info "🔐 Devise JWT is available - no expiration configured"
      else
        Rails.logger.error "❌ Devise JWT is NOT available - check gem installation"
      end
      
      # Check OmniAuth providers
      if Devise.respond_to?(:omniauth_providers) && Devise.omniauth_providers.any?
        Rails.logger.info "🔐 OmniAuth Providers: #{Devise.omniauth_providers.join(', ')}"
      end
      
      # Log JWT configuration status
      Rails.logger.info "🔐 JWT Configuration: No expiration, API-only mode"
    end
  end
end