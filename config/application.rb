# config/application.rb - Fixed ActionCable configuration with Kenya Timezone

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
    # 🌍 TIMEZONE CONFIGURATION (KENYA)
    # ===========================================
    
    # Set application timezone to Kenya (East Africa Time - UTC+3)
    config.time_zone = 'Nairobi'
    
    # Keep database storage in UTC (recommended best practice)
    config.active_record.default_timezone = :utc
    
    # ===========================================
    # 🔧 API-ONLY WITH ACTIONCABLE CONFIGURATION (FIXED)
    # ===========================================
    
    # Keep API-only mode but add back necessary middleware for ActionCable
    config.api_only = true
    
    # CRITICAL: Add back middleware needed for ActionCable in API mode
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore
    config.middleware.use ActionDispatch::Flash
    
    # ===========================================
    # 🔌 ACTIONCABLE CONFIGURATION (CRITICAL FIX)
    # ===========================================
    
    # Disable request forgery protection for ActionCable (required for API mode)
    config.action_cable.disable_request_forgery_protection = true
    
    # Allow ActionCable connections from any origin in development/testing
    config.action_cable.allow_same_origin_as_host = true
    
    # Ensure ActionCable is properly mounted
    config.action_cable.mount_path = '/cable'
    
    # ===========================================
    # 📁 LARGE FILE UPLOAD CONFIGURATION (FIXED)
    # ===========================================
    
    # Fix for 119MB APK uploads - increase request size limit
    config.action_dispatch.max_request_size = 250 * 1024 * 1024 # 250MB in bytes
    
    # ===========================================
    # 🍪 SESSION CONFIGURATION (FIXED - No Session Timeout)
    # ===========================================
    
    # Configure session store - REMOVED expire_after to fix JWT conflicts
    config.session_store :cookie_store, 
      key: '_glt_api_session',
      secure: false,  # Set to true when HTTPS is working
      httponly: true,
      same_site: :lax
      # REMOVED: expire_after: 1.hour  # This was causing JWT auth conflicts
    
    # ===========================================
    # 🌐 CORS CONFIGURATION (FIXED FOR ACTIONCABLE)
    # ===========================================
    
    config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins '*'  # Permissive for debugging
        resource '*', 
          headers: :any,
          methods: [:get, :post, :put, :patch, :delete, :options, :head],
          credentials: false
        
        # CRITICAL: Specific configuration for ActionCable WebSocket connections
        resource '/cable',
          headers: :any,
          methods: [:get, :post],
          credentials: false
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
    # 🔧 ADDITIONAL ACTIONCABLE INITIALIZATION
    # ===========================================
    
    # Ensure ActionCable server is properly initialized
    config.after_initialize do
      # Force ActionCable server initialization
      ActionCable.server.config.logger = Rails.logger
      
      # Log ActionCable configuration for debugging
      Rails.logger.info "ActionCable Server initialized: #{ActionCable.server.inspect}"
      Rails.logger.info "ActionCable mount path: #{config.action_cable.mount_path}"
    end
  end
end