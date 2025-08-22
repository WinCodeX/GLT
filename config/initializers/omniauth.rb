# config/initializers/omniauth.rb
# OmniAuth configuration for API-only Rails app with JWT authentication

# ===========================================
# 🔐 OMNIAUTH CONFIGURATION
# ===========================================

# Configure allowed request methods
OmniAuth.config.allowed_request_methods = %i[post get]
OmniAuth.config.silence_get_warning = true

# Configure test mode for development/test
OmniAuth.config.test_mode = Rails.env.test?

# Logging
OmniAuth.config.logger = Rails.logger

# ===========================================
# 🔧 SECURITY CONFIGURATION  
# ===========================================

# CSRF Protection - Disable for API mode
OmniAuth.config.request_validation_phase = nil

# Path prefix for OmniAuth routes
OmniAuth.config.path_prefix = '/api/v1/auth'

# ===========================================
# 🚫 FAILURE HANDLING
# ===========================================

# Custom failure handling for API responses
OmniAuth.config.on_failure = Proc.new do |env|
  # Extract error information
  message_key = env['omniauth.error.type']
  error_type = env['omniauth.error.type'] || 'unknown_error'
  description = env['omniauth.error']&.message || 'OAuth authentication failed'
  
  # Log the failure
  Rails.logger.error "🚫 OmniAuth failure: #{error_type} - #{description}"
  
  # Create a proper API error response
  [422, 
   { 'Content-Type' => 'application/json' }, 
   [{ 
     status: 'error',
     message: 'OAuth authentication failed',
     error: error_type,
     description: description,
     code: 'oauth_failure'
   }.to_json]]
end

# ===========================================
# 🔑 GOOGLE OAUTH PROVIDER CONFIGURATION
# ===========================================

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
           ENV['GOOGLE_CLIENT_ID'] || Rails.application.credentials.dig(:google_oauth, :client_id),
           ENV['GOOGLE_CLIENT_SECRET'] || Rails.application.credentials.dig(:google_oauth, :client_secret),
           {
             # ===========================================
             # 🎯 BASIC CONFIGURATION
             # ===========================================
             name: 'google_oauth2',
             scope: 'email,profile',
             prompt: 'select_account',
             
             # ===========================================
             # 🔒 SECURITY CONFIGURATION
             # ===========================================
             provider_ignores_state: false,
             
             # ===========================================
             # 📱 API-SPECIFIC CONFIGURATION
             # ===========================================
             # Callback path for API
             callback_path: '/api/v1/auth/google_oauth2/callback',
             
             # Authorization parameters
             authorize_params: {
               access_type: 'offline',
               approval_prompt: '',
               prompt: 'select_account'
             },
             
             # ===========================================
             # 🎨 UI CONFIGURATION
             # ===========================================
             image_aspect_ratio: 'square',
             image_size: 150,
             
             # ===========================================
             # 🔧 ADVANCED CONFIGURATION
             # ===========================================
             # Skip session requirement for API mode
             client_options: {
               ssl: { verify: Rails.env.production? }
             },
             
             # ===========================================
             # 🌐 ENVIRONMENT-SPECIFIC SETTINGS
             # ===========================================
             setup: lambda do |env|
               request = Rack::Request.new(env)
               
               # Set redirect URI based on environment
               if Rails.env.development?
                 env['omniauth.strategy'].options[:redirect_uri] = 'http://localhost:3000/api/v1/auth/google_oauth2/callback'
               elsif Rails.env.production?
                 env['omniauth.strategy'].options[:redirect_uri] = "#{ENV['BASE_URL']}/api/v1/auth/google_oauth2/callback"
               end
               
               Rails.logger.debug "🔐 OAuth setup for #{request.path} with redirect: #{env['omniauth.strategy'].options[:redirect_uri]}"
             end
           }
end

# ===========================================
# 🔧 ADDITIONAL CONFIGURATIONS
# ===========================================

# Ensure OmniAuth works with ActionController::API
module OmniAuth
  module Strategy
    def session
      # Provide a fallback if session is not available
      request.env['rack.session'] || {}
    end
  end
end

# ===========================================
# 🧪 DEVELOPMENT/TEST HELPERS
# ===========================================

if Rails.env.development? || Rails.env.test?
  # Add test credentials if environment variables are not set
  unless ENV['GOOGLE_CLIENT_ID'].present?
    Rails.logger.warn "⚠️  GOOGLE_CLIENT_ID not set. Using development defaults."
  end
  
  unless ENV['GOOGLE_CLIENT_SECRET'].present?
    Rails.logger.warn "⚠️  GOOGLE_CLIENT_SECRET not set. Using development defaults."
  end
  
  # Enable detailed logging in development
  OmniAuth.config.logger.level = Logger::DEBUG if Rails.env.development?
end

# ===========================================
# 🔍 LOGGING CONFIGURATION
# ===========================================

# Log OmniAuth events for debugging
Rails.application.config.after_initialize do
  if defined?(OmniAuth)
    Rails.logger.info "✅ OmniAuth initialized with providers: #{OmniAuth.strategies.map(&:name).join(', ')}"
    Rails.logger.info "🔑 Google OAuth Client ID: #{ENV['GOOGLE_CLIENT_ID']&.first(10)}..." if ENV['GOOGLE_CLIENT_ID']
  end
end