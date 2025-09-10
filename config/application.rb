# config/application.rb - Fixed session configuration

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
    # 🔧 API-ONLY WITH SESSIONS CONFIGURATION
    # ===========================================
    
    # Keep API-only mode but add back necessary middleware for OAuth
    config.api_only = true
    
    # ===========================================
    # 📁 LARGE FILE UPLOAD CONFIGURATION (FIXED)
    # ===========================================
    
    # Fix for 119MB APK uploads - increase request size limit
    config.action_dispatch.max_request_size = 250 * 1024 * 1024 # 250MB in bytes
    
    # ===========================================
    # 🍪 SESSION CONFIGURATION (FIXED)
    # ===========================================
    
    # Configure session store first
    config.session_store :cookie_store, 
      key: '_glt_api_session',
      secure: false,  # Set to true when HTTPS is working
      httponly: true,
      same_site: :lax,
      expire_after: 1.hour
    
    # Add middleware in correct order
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore, config.session_options
    
    # Flash middleware (sometimes needed for session functionality)
    config.middleware.use ActionDispatch::Flash
    
    # ===========================================
    # 🌐 CORS CONFIGURATION
    # ===========================================
    
    config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins '*'  # Permissive for debugging
        resource '*', 
          headers: :any,
          methods: [:get, :post, :put, :patch, :delete, :options, :head],
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
  end
end