# config/application.rb - Secure configuration

if defined?(Dotenv)
  require 'dotenv/rails-now'
end
require_relative "boot"

require "rails"
# Pick the frameworks you want:
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
    config.api_only = true

    # ===========================================
    # 🔒 SECURE SSL CONFIGURATION
    # ===========================================
    
    # Force SSL in production (Render provides SSL certificates)
    config.force_ssl = Rails.env.production?
    
    # Secure headers configuration
    if Rails.env.production?
      config.ssl_options = {
        redirect: { exclude: ->(request) { request.path.start_with?('/health') } },
        secure_cookies: true,
        hsts: {
          expires: 1.year,
          subdomains: true,
          preload: true
        }
      }
    end

    # ===========================================
    # 🔐 SESSION CONFIGURATION FOR OAUTH
    # ===========================================
    
    config.session_store :cookie_store, 
      key: '_glt_api_session',
      secure: Rails.env.production?,  # HTTPS-only cookies in production
      httponly: true,
      same_site: :lax,
      expire_after: 24.hours

    # Add session middleware
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore, config.session_options

    # ===========================================
    # 🌐 SECURE CORS CONFIGURATION
    # ===========================================
    
    config.middleware.insert_before 0, Rack::Cors do
      allow do
        if Rails.env.production?
          # Production: Use HTTPS URLs only
          origins [
            'https://glt-53x8.onrender.com',     # Your Render URL with HTTPS
            'https://yourapp.com',               # Your custom domain (if you have one)
            'https://www.yourapp.com'            # Your custom domain (if you have one)
          ]
        else
          # Development: Allow localhost
          origins [
            'http://localhost:3000', 
            'http://127.0.0.1:3000', 
            'http://0.0.0.0:3000'
          ]
        end
        
        resource '*', 
          headers: :any,
          methods: [:get, :post, :put, :patch, :delete, :options, :head],
          credentials: true
      end
    end

    # ===========================================
    # 🛡️ SECURITY HEADERS
    # ===========================================
    
    if Rails.env.production?
      # Security headers middleware
      config.middleware.use Rack::Attack if defined?(Rack::Attack)
      
      # Content Security Policy
      config.content_security_policy do |policy|
        policy.default_src :self
        policy.font_src    :self, :data
        policy.img_src     :self, :data, :https
        policy.object_src  :none
        policy.script_src  :self
        policy.style_src   :self, :unsafe_inline
        policy.connect_src :self, :https
      end
      
      config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
      config.content_security_policy_nonce_directives = %w(script-src)
    end

    # ===========================================
    # 🛠️ GENERATORS CONFIGURATION
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