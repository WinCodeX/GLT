# config/initializers/devise.rb - Fixed for JWT + OAuth

Devise.setup do |config|
  # ===========================================
  # 🔧 BASIC DEVISE CONFIGURATION
  # ===========================================
  
  config.mailer_sender = 'noreply@packagedelivery.com'
  
  # ==> ORM configuration
  require 'devise/orm/active_record'

  # ==> Basic Authentication Configuration
  config.case_insensitive_keys = [:email]
  config.strip_whitespace_keys = [:email]
  
  # ===========================================
  # 📱 API-ONLY CONFIGURATION
  # ===========================================
  
  # Skip session storage for API-only mode (except where needed)
  config.skip_session_storage = [:http_auth]
  
  # Set navigational formats for API
  config.navigational_formats = []
  
  # Response format
  config.responder.error_status = :unprocessable_entity
  config.responder.redirect_status = :see_other

  # ==> Password Configuration
  config.password_length = 8..128
  config.email_regexp = /\A[^@\s]+@[^@\s]+\z/
  
  # Use bcrypt with appropriate cost
  config.stretches = Rails.env.test? ? 1 : 12

  # ==> Security Configuration
  config.timeout_in = 24.hours
  config.lock_strategy = :failed_attempts
  config.unlock_strategy = :both
  config.maximum_attempts = 5
  config.unlock_in = 1.hour
  config.last_attempt_warning = true
  config.reset_password_within = 6.hours

  # ==> Confirmation Configuration  
  config.allow_unconfirmed_access_for = 0.days
  config.confirm_within = 3.days
  config.reconfirmable = true

  # ==> Rememberable Configuration
  config.expire_all_remember_me_on_sign_out = true
  config.rememberable_options = {
    secure: Rails.env.production?,
    httponly: true,
    same_site: :lax
  }

  # ==> Security Configuration
  config.paranoid = true
  config.sign_out_all_scopes = true
  config.sign_in_after_change_password = true
  config.sign_out_via = :delete

  # ===========================================
  # 🔐 JWT CONFIGURATION (FIXED)
  # ===========================================
  
  config.jwt do |jwt|
    # Use environment variable or Rails credentials for JWT secret
    jwt.secret = ENV['DEVISE_JWT_SECRET_KEY'] || 
                 Rails.application.credentials.jwt_secret_key || 
                 Rails.application.secret_key_base

    # ===========================================
    # 📍 JWT DISPATCH ROUTES (Which routes get JWT tokens)
    # ===========================================
    jwt.dispatch_requests = [
      # Regular authentication
      ['POST', %r{^/api/v1/login$}],
      ['POST', %r{^/api/v1/signup$}],
      
      # Google OAuth - these routes will also get JWT tokens
      ['GET', %r{^/api/v1/auth/google_oauth2/callback$}],
      ['POST', %r{^/api/v1/auth/google_oauth2/callback$}],
      ['POST', %r{^/api/v1/auth/google/login$}],
      ['POST', %r{^/api/v1/google_login$}],
      
      # Mobile auth endpoints
      ['POST', %r{^/mobile/v1/auth/google$}]
    ]
    
    # ===========================================
    # 🚪 JWT REVOCATION ROUTES (Logout endpoints)  
    # ===========================================
    jwt.revocation_requests = [
      ['DELETE', %r{^/api/v1/logout$}],
      ['POST', %r{^/api/v1/logout$}]  # Allow POST for logout compatibility
    ]
    
    # ===========================================
    # ⏰ JWT TOKEN CONFIGURATION
    # ===========================================
    jwt.expiration_time = 24.hours.to_i
    jwt.algorithm = 'HS256'
    
    # ===========================================
    # 🔄 JWT REVOCATION STRATEGY
    # ===========================================
    # Using Null strategy for simplicity - tokens expire naturally
    # You can switch to JTIMatcher for immediate revocation if needed
    # jwt.revocation_strategy = Devise::JWT::RevocationStrategies::JTIMatcher
  end

  # ===========================================
  # 🔐 GOOGLE OAUTH CONFIGURATION (FIXED)
  # ===========================================
  
  # Configure OmniAuth providers
  config.omniauth :google_oauth2,
                  ENV['GOOGLE_CLIENT_ID'] || Rails.application.credentials.dig(:google_oauth, :client_id),
                  ENV['GOOGLE_CLIENT_SECRET'] || Rails.application.credentials.dig(:google_oauth, :client_secret),
                  {
                    # ===========================================
                    # 🎯 OAUTH SCOPE & PERMISSIONS
                    # ===========================================
                    scope: 'email,profile',
                    prompt: 'select_account',
                    access_type: 'offline',
                    
                    # ===========================================
                    # 📱 API-SPECIFIC OAUTH SETTINGS
                    # ===========================================
                    # Don't skip JWT for OAuth - we want JWT tokens after OAuth
                    skip_jwt: false,
                    
                    # Callback configuration for API
                    callback_path: '/api/v1/auth/google_oauth2/callback',
                    path_prefix: '/api/v1/auth',
                    
                    # ===========================================
                    # 🔒 SECURITY SETTINGS
                    # ===========================================
                    provider_ignores_state: false,
                    
                    # ===========================================
                    # 🎨 UI CUSTOMIZATION
                    # ===========================================
                    image_aspect_ratio: 'square',
                    image_size: 150,
                    
                    # ===========================================
                    # 🔧 CLIENT OPTIONS
                    # ===========================================
                    client_options: {
                      ssl: { 
                        verify: Rails.env.production? 
                      }
                    }
                  }

  # ===========================================
  # 🎯 WARDEN CONFIGURATION FOR API
  # ===========================================
  
  config.warden do |manager|
    # Default strategies
    manager.default_strategies(scope: :user).unshift :jwt_authenticatable
    
    # Failure app for API responses
    manager.failure_app = lambda do |env|
      # Return JSON error for API requests
      result = [401, 
                { 'Content-Type' => 'application/json' }, 
                [{ 
                  status: 'error',
                  message: 'Authentication required',
                  code: 'unauthenticated'
                }.to_json]]
      result
    end
  end

  # ===========================================
  # 🔧 API-SPECIFIC OVERRIDES
  # ===========================================
  
  # Override default URL options for API
  config.sign_out_via = [:delete, :post]  # Allow both for API flexibility
  
  # ===========================================
  # 🧪 DEVELOPMENT/TEST CONFIGURATION
  # ===========================================
  
  if Rails.env.development? || Rails.env.test?
    # Reduce password stretches for faster tests
    config.stretches = 1 if Rails.env.test?
    
    # Allow unconfirmed access in development
    config.allow_unconfirmed_access_for = 30.days if Rails.env.development?
    
    # Disable sending emails in test
    config.mailer = 'DeviseMailer' unless Rails.env.test?
  end

  # ===========================================
  # 🔍 LOGGING AND DEBUGGING
  # ===========================================
  
  # Log Devise configuration (Fixed - removed problematic JWT access)
  Rails.application.config.after_initialize do
    if defined?(Devise)
      Rails.logger.info "✅ Devise initialized"
      
      # Check if JWT is available
      if defined?(Devise::JWT)
        Rails.logger.info "🔐 Devise JWT is available"
      end
      
      # Check OmniAuth providers
      if Devise.respond_to?(:omniauth_providers) && Devise.omniauth_providers.any?
        Rails.logger.info "🔐 OmniAuth Providers: #{Devise.omniauth_providers.join(', ')}"
      end
    end
  end
end