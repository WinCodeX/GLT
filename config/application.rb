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
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module GltApi
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w(assets tasks))

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # ===========================================
    # 🔐 SESSION CONFIGURATION FOR OAUTH
    # ===========================================
    # Add sessions back for OAuth while keeping API-only mode
    # Sessions will be used for OAuth flow, JWT for everything else
    
    config.session_store :cookie_store, 
      key: '_glt_api_session',
      secure: Rails.env.production?,
      httponly: true,
      same_site: :lax

    # Add session middleware back (required for OmniAuth)
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore, config.session_options

    # ===========================================
    # ⚙️ CORS CONFIGURATION - FIXED
    # ===========================================
    
    config.middleware.insert_before 0, Rack::Cors do
      allow do
        if Rails.env.production?
          # Production: Include your actual Render URL
          origins [
            'https://glt-53x8.onrender.com',  # Your actual Render URL
            'https://yourapp.com',            # Your custom domain (if you have one)
            'https://www.yourapp.com'         # Your custom domain (if you have one)
          ]
        else
          # Development: Allow localhost
          origins [
            'http://localhost:3000', 
            'http://127.0.0.1:3000', 
            'http://0.0.0.0:3000',
            'http://192.168.1.100:3000'  # Add your local IP if needed
          ]
        end
        
        resource '*', 
          headers: :any,
          methods: [:get, :post, :put, :patch, :delete, :options, :head],
          credentials: true
      end
    end

    # ===========================================
    # 🔒 SSL CONFIGURATION - DISABLED FOR DEBUGGING
    # ===========================================
    
    # Temporarily disable force SSL to debug
    # Re-enable this once OAuth is working
    # config.force_ssl = Rails.env.production?
    config.force_ssl = false

    # ===========================================
    # 🛠️ GENERATORS CONFIGURATION
    # ===========================================
    
    # Configure generators for API
    config.generators do |g|
      g.test_framework :rspec
      g.skip_routes true
      g.skip_helper true
      g.skip_views true
      g.skip_assets true
    end
  end
end