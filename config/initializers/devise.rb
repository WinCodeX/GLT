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
  # 🔐 JWT CONFIGURATION (RE-ENABLED - SIMPLIFIED)
  # ===========================================
  
  config.jwt do |jwt|
    # Use environment variable or Rails credentials for JWT secret
    jwt.secret = ENV['DEVISE_JWT_SECRET_KEY'] || 
                 Rails.application.credentials.jwt_secret_key || 
                 Rails.application.secret_key_base

    # JWT dispatch routes - simplified
    jwt.dispatch_requests = [
      ['POST', %r{^/api/v1/login$}],
      ['POST', %r{^/api/v1/signup$}],
      ['POST', %r{^/api/v1/google_login$}]
    ]
    
    # JWT revocation routes
    jwt.revocation_requests = [
      ['DELETE', %r{^/api/v1/logout$}],
      ['POST', %r{^/api/v1/logout$}]
    ]
    
    # JWT token configuration
    jwt.expiration_time = 24.hours.to_i
    jwt.algorithm = 'HS256'
  end

  # ===========================================
  # 🔐 GOOGLE OAUTH CONFIGURATION (FIXED)
  # ===========================================
  
  # Configure OmniAuth providers
  config.omniauth :google_oauth2,
                  ENV['GOOGLE_CLIENT_ID'] || Rails.application.credentials.dig(:google_oauth, :client_id),
                  ENV['GOOGLE_CLIENT_SECRET'] || Rails.application.credentials.dig(:google_oauth, :client_secret),
                  {
                    # OAuth scope & permissions
                    scope: 'email,profile',
                    prompt: 'select_account',
                    access_type: 'offline',
                    
                    # API-specific OAuth settings
                    skip_jwt: false,
                    
                    # Callback configuration for API
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