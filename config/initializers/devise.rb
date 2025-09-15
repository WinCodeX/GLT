# config/initializers/devise.rb - FIXED: JWT session expiration issues resolved

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
  
  # CRITICAL FIX: Complete session storage skip for ALL auth strategies
  config.skip_session_storage = [:http_auth, :params_auth, :token_auth, :database_auth, :jwt_auth]
  
  # CRITICAL: No navigational formats for pure API
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
  # 🔥 CRITICAL FIX: NO SESSION TIMEOUTS FOR JWT
  # ===========================================
  
  # REMOVED ALL SESSION-BASED CONFIGURATIONS THAT INTERFERE WITH JWT:
  # - NO timeout_in (this was causing false expiration)
  # - NO rememberable (session-based)  
  # - NO confirmable (email-based, not needed for API)
  # - NO lockable (can cause JWT issues)
  
  # ==> Security Configuration (JWT-compatible only)
  config.paranoid = true
  config.sign_out_all_scopes = false  # Allow single-scope signout for JWT
  config.sign_in_after_change_password = false  # API doesn't auto sign-in
  config.sign_out_via = [:delete, :post]  # Both methods for API flexibility

  # ===========================================
  # 🔐 JWT CONFIGURATION (FIXED - Session expiration issues resolved)
  # ===========================================
  
  config.jwt do |jwt|
    # CRITICAL FIX: Single consistent secret key source
    jwt_secret = ENV['DEVISE_JWT_SECRET_KEY']
    
    if jwt_secret.blank?
      jwt_secret = Rails.application.secret_key_base
      Rails.logger.warn "⚠️ Using Rails secret_key_base for JWT. Set DEVISE_JWT_SECRET_KEY for production."
    end
    
    jwt.secret = jwt_secret
    
    # NOTE: Revocation strategy is configured in User model, not here
    
    # Log the secret being used (first 10 chars only for security)
    Rails.logger.info "🔐 JWT Secret configured: #{jwt_secret[0..10]}..."

    # FIXED: Correct dispatch routes that actually match your API
    jwt.dispatch_requests = [
      ['POST', %r{^/api/v1/login$}],
      ['POST', %r{^/api/v1/sessions$}],  # Standard Devise sessions
      ['POST', %r{^/api/v1/google_login$}],
      ['POST', %r{^/users/sign_in$}],    # Standard Devise route
    ]
    
    # FIXED: Correct revocation routes
    jwt.revocation_requests = [
      ['DELETE', %r{^/api/v1/logout$}],
      ['POST', %r{^/api/v1/logout$}],
      ['DELETE', %r{^/api/v1/sessions$}],
      ['DELETE', %r{^/users/sign_out$}],  # Standard Devise route
    ]
    
    # 🔥 CRITICAL: NO EXPIRATION - Tokens never expire
    jwt.expiration_time = 10.years.to_i
    jwt.algorithm = 'HS256'
    
    # Add debugging for JWT operations
    if Rails.env.development?
      Rails.logger.info "🔐 JWT dispatch routes: #{jwt.dispatch_requests.map(&:last)}"
      Rails.logger.info "🔐 JWT revocation routes: #{jwt.revocation_requests.map(&:last)}"
      Rails.logger.info "🔐 JWT expiration: #{jwt.expiration_time || 'NEVER'}"
    end
  end

  # ===========================================
  # 🔐 GOOGLE OAUTH CONFIGURATION (VERIFIED)
  # ===========================================
  
  config.omniauth :google_oauth2,
                  ENV['GOOGLE_CLIENT_ID'],
                  ENV['GOOGLE_CLIENT_SECRET'],
                  {
                    scope: 'email,profile',
                    prompt: 'select_account',
                    access_type: 'offline',
                    skip_jwt: false,  # Allow JWT generation
                    callback_path: '/api/v1/auth/google_oauth2/callback',
                    provider_ignores_state: false,
                    image_aspect_ratio: 'square',
                    image_size: 150,
                    client_options: {
                      ssl: { verify: Rails.env.production? }
                    }
                  }

  # ===========================================
  # 🧪 ENVIRONMENT-SPECIFIC CONFIGURATION
  # ===========================================
  
  if Rails.env.development? || Rails.env.test?
    config.stretches = 1 if Rails.env.test?
    config.mailer = 'DeviseMailer' if Rails.env.development?
  end

  # ===========================================
  # 🔍 COMPREHENSIVE LOGGING FOR DEBUGGING
  # ===========================================
  
  Rails.application.config.after_initialize do
    if defined?(Devise)
      Rails.logger.info "=" * 50
      Rails.logger.info "🔐 DEVISE-JWT CONFIGURATION SUMMARY"
      Rails.logger.info "=" * 50
      
      # Check Devise JWT availability
      if defined?(Devise::JWT)
        Rails.logger.info "✅ Devise JWT gem: AVAILABLE"
        
        # Check JWT configuration
        begin
          jwt_config = Devise.jwt
          Rails.logger.info "✅ JWT secret: CONFIGURED (#{jwt_config.secret[0..10]}...)"
          Rails.logger.info "✅ JWT expiration: #{jwt_config.expiration_time || 'NEVER EXPIRES'}"
          Rails.logger.info "✅ JWT algorithm: #{jwt_config.algorithm}"
          Rails.logger.info "✅ JWT dispatch routes: #{jwt_config.dispatch_requests.size} configured"
          Rails.logger.info "✅ JWT revocation routes: #{jwt_config.revocation_requests.size} configured"
        rescue => e
          Rails.logger.error "❌ JWT configuration error: #{e.message}"
        end
      else
        Rails.logger.error "❌ Devise JWT gem: NOT AVAILABLE"
      end
      
      # Check OmniAuth providers
      if Devise.respond_to?(:omniauth_providers) && Devise.omniauth_providers.any?
        Rails.logger.info "✅ OmniAuth providers: #{Devise.omniauth_providers.join(', ')}"
      else
        Rails.logger.warn "⚠️ No OmniAuth providers configured"
      end
      
      # Check environment variables
      Rails.logger.info "🔐 Environment check:"
      Rails.logger.info "  DEVISE_JWT_SECRET_KEY: #{ENV['DEVISE_JWT_SECRET_KEY'].present? ? 'SET' : 'NOT SET'}"
      Rails.logger.info "  GOOGLE_CLIENT_ID: #{ENV['GOOGLE_CLIENT_ID'].present? ? 'SET' : 'NOT SET'}"
      Rails.logger.info "  GOOGLE_CLIENT_SECRET: #{ENV['GOOGLE_CLIENT_SECRET'].present? ? 'SET' : 'NOT SET'}"
      
      Rails.logger.info "=" * 50
      Rails.logger.info "🔐 DEVISE CONFIGURATION COMPLETE"
      Rails.logger.info "=" * 50
    end
  end
end