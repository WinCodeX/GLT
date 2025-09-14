# config/initializers/rack_attack.rb - FIXED: Exclude auth endpoints from rate limiting

# CRITICAL FIX: Exclude authentication endpoints from rate limiting
# This prevents legitimate users from being blocked during normal app usage

Rack::Attack.throttle('api_general', limit: 1000, period: 1.hour) do |req|
  # Only throttle non-auth API requests
  if req.path.start_with?('/api/') && !auth_endpoint?(req.path)
    req.ip
  end
end

# CRITICAL FIX: Separate, more permissive throttling for auth endpoints
Rack::Attack.throttle('auth_endpoints', limit: 50, period: 1.hour) do |req|
  if auth_endpoint?(req.path)
    req.ip
  end
end

# Helper method to identify authentication endpoints
def auth_endpoint?(path)
  auth_paths = [
    '/api/v1/login',
    '/api/v1/sessions',
    '/api/v1/google_login',
    '/api/v1/logout',
    '/api/v1/auth/',
    '/users/sign_in',
    '/users/sign_out'
  ]
  
  auth_paths.any? { |auth_path| path.include?(auth_path) }
end

# OPTIONAL: Allow certain endpoints to be completely unrestricted
Rack::Attack.safelist('health_checks') do |req|
  req.path == '/up' || 
  req.path == '/health' || 
  req.path.start_with?('/health/')
end