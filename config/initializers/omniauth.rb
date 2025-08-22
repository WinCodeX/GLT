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

# CSRF Protection - Disable for API mode since we handle auth differently
OmniAuth.config.request_validation_phase = nil

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
# 🔧 DEVELOPMENT/TEST HELPERS
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
    Rails.logger.info "✅ OmniAuth initialized"
    Rails.logger.info "🔑 Google OAuth Client ID: #{ENV['GOOGLE_CLIENT_ID']&.first(10)}..." if ENV['GOOGLE_CLIENT_ID']
  end
end