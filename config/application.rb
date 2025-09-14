# config/application.rb - FIXED: Pure JWT API without session interference

if defined?(Dotenv)
  require 'dotenv/rails-now'
end
require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"

Bundler.require(*Rails.groups)

module GltApi
  class Application < Rails::Application
    config.load_defaults 7.1
    config.autoload_lib(ignore: %w(assets tasks))
    
    # ===========================================
    # 🔧 PURE API-ONLY CONFIGURATION (FIXED)
    # ===========================================
    
    # Strict API-only mode - no session-based authentication
    config.api_only = true
    
    # ===========================================
    # 📁 LARGE FILE UPLOAD CONFIGURATION
    # ===========================================
    
    # Fix for 119MB APK uploads - increase request size limit
    config.action_dispatch.max_request_size = 250 * 1024 * 1024 # 250MB in bytes
    
    # ===========================================
    # 🚫 REMOVED: SESSION CONFIGURATION THAT WAS CAUSING JWT CONFLICTS
    # ===========================================
    
    # CRITICAL FIX: Removed all session-related middleware and configuration
    # The following was causing JWT token authentication to expire:
    # - config.session_store :cookie_store with expire_after: 1.hour
    # - ActionDispatch::Cookies middleware
    # - ActionDispatch::Session::CookieStore middleware  
    # - ActionDispatch::Flash middleware
    #
    # JWT tokens are stateless and don't require sessions
    
    # ===========================================
    # 🌐 CORS CONFIGURATION
    # ===========================================
    
    config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins '*'  # Permissive for debugging
        resource '*', 
          headers: :any,
          methods: [:get, :post, :put, :patch, :delete, :options, :head],
          credentials: false  # IMPORTANT: false for JWT-based auth
      end
    end
    
    # ===========================================
    # 🔓 SSL CONFIGURATION (DISABLED FOR NOW)
    # ===========================================
    
    # Disable SSL until basic functionality works
    config.force_ssl = false
    
    # ===========================================
    # 🛠️ GENERATORS
    # ===========================================
    
    config.generators do |g|
      g.test_framework :rspec
      g.skip_routes true
      g.skip_helper true
      g.skip_views true
      g.skip_assets true
    end
    
    # ===========================================
    # 🔧 JWT-SPECIFIC CONFIGURATIONS
    # ===========================================
    
    # Ensure no session storage interference with JWT
    config.middleware.delete ActionDispatch::Cookies
    config.middleware.delete ActionDispatch::Session::CookieStore
    config.middleware.delete ActionDispatch::Flash
    
    # Optional: Add request/response logging for debugging
    if Rails.env.development?
      config.log_level = :debug
      
      # Log authentication-related requests
      config.middleware.use Rack::CommonLogger, Rails.logger
    end
  end
end