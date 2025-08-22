# app/middleware/conditional_session_middleware.rb
# This middleware conditionally enables/disables sessions based on the route
# Sessions are enabled for OAuth routes, disabled for API routes

class ConditionalSessionMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    request = ActionDispatch::Request.new(env)
    
    # Enable sessions for OAuth routes
    if oauth_route?(request.path)
      Rails.logger.debug "🔐 Enabling sessions for OAuth route: #{request.path}"
      @app.call(env)
    elsif public_route?(request.path)
      # Public routes that might need sessions
      Rails.logger.debug "🌐 Enabling sessions for public route: #{request.path}" 
      @app.call(env)
    elsif api_route?(request.path)
      # Disable sessions for API routes to prevent OmniAuth interference
      Rails.logger.debug "📱 Disabling sessions for API route: #{request.path}"
      env['rack.session.options'] = { skip: true }
      @app.call(env)
    else
      # Default behavior - enable sessions
      @app.call(env)
    end
  end

  private

  def oauth_route?(path)
    # OAuth related routes that need sessions
    oauth_patterns = [
      %r{^/api/v1/auth/google},
      %r{^/auth/},
      %r{^/users/auth/},
      %r{^/api/v1/users/auth/}
    ]
    
    oauth_patterns.any? { |pattern| path.match?(pattern) }
  end

  def public_route?(path)
    # Public routes that might need sessions for tracking
    public_patterns = [
      %r{^/public/},
      %r{^/webhooks/}
    ]
    
    public_patterns.any? { |pattern| path.match?(pattern) }
  end

  def api_route?(path)
    # Pure API routes that should be stateless
    api_patterns = [
      %r{^/api/v1/(?!auth/)},  # API routes except auth
      %r{^/health},
      %r{^/up}
    ]
    
    api_patterns.any? { |pattern| path.match?(pattern) }
  end
end
