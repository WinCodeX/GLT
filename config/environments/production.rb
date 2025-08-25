require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false

  # Enable serving static files from public/
  config.public_file_server.enabled = ENV['RAILS_SERVE_STATIC_FILES'].present?
  
  # Configure static file serving with proper headers for performance
  if config.public_file_server.enabled
    config.public_file_server.headers = {
      'Cache-Control' => 'public, max-age=31536000' # 1 year cache for static assets
    }
  end

  # ==========================================
  # 🗄️ STORAGE CONFIGURATION - FIXED
  # ==========================================
  
  # Use Cloudflare R2 storage in production
  config.active_storage.service = :cloudflare

  # ==========================================
  # 🔧 URL & HOST CONFIGURATION
  # ==========================================
  Rails.application.routes.default_url_options[:host] = 'https://glt-53x8.onrender.com'

  # 📸 AVATAR HOSTS CONFIGURATION
  config.x.avatar_hosts = [
    'https://glt-53x8.onrender.com',
    ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 'https://pub-6361267c2d64075820ce8724feff.r2.dev'
  ]

  # ==========================================
  # 🚀 PERFORMANCE & CACHING
  # ==========================================
  
  # Fallback to memory cache if Redis not available
  config.cache_store = :memory_store, { 
    size: 128 * 1024 * 1024,
    expires_in: 1.hour 
  }

  # Enable Active Storage optimizations for R2
  config.active_storage.variant_processor = :mini_magick
  config.active_storage.draw_routes = false # Disable if using custom routes

  # ==========================================
  # 🔒 SECURITY & SSL
  # ==========================================
  
  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Enable DNS rebinding protection and other `Host` header attacks.
  config.hosts = [
    "glt-53x8.onrender.com",     # Your production domain
    /.*\.onrender\.com/,         # Allow Render subdomains
    /.*\.herokuapp\.com/         # If you ever use Heroku
  ]
  
  # Skip DNS rebinding protection for health check endpoints
  config.host_authorization = { 
    exclude: ->(request) { 
      request.path == "/up" || 
      request.path == "/health" || 
      request.path.start_with?("/health/")
    } 
  }

  # ==========================================
  # 📱 CORS CONFIGURATION (for Expo Go/React Native)
  # ==========================================
  
  # Enable CORS for mobile app access
  config.middleware.insert_before 0, Rack::Cors do
    allow do
      # In production, be more specific about origins
      origins ENV['ALLOWED_ORIGINS']&.split(',') || [
        'http://localhost:8081',           # Expo Go default
        'exp://192.168.100.73:8081',       # Expo Go with your IP
        /^https:\/\/.*\.expo\.dev$/,       # Expo hosted apps
        /^https:\/\/.*\.exp\.direct$/      # Expo direct URLs
      ]
      
      resource '*',
        headers: :any,
        methods: [:get, :post, :put, :patch, :delete, :options, :head],
        expose: ['Authorization'],
        credentials: false
    end
  end

  # ==========================================
  # 📝 LOGGING CONFIGURATION
  # ==========================================
  
  # Log to STDOUT by default (good for containerized deployments)
  config.logger = ActiveSupport::Logger.new(STDOUT)
    .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
    .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

  # Prepend all log lines with the following tags.
  config.log_tags = [ :request_id ]

  # Set log level
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # ==========================================
  # 📧 ACTION MAILER CONFIGURATION
  # ==========================================
  
  config.action_mailer.perform_caching = false
  config.action_mailer.default_url_options = { host: 'glt-53x8.onrender.com', protocol: 'https' }

  # ==========================================
  # 🌍 INTERNATIONALIZATION
  # ==========================================
  
  # Enable locale fallbacks for I18n
  config.i18n.fallbacks = true

  # Don't log any deprecations in production
  config.active_support.report_deprecations = false

  # ==========================================
  # 🗄️ DATABASE CONFIGURATION
  # ==========================================
  
  # Do not dump schema after migrations in production
  config.active_record.dump_schema_after_migration = false

  # Compress responses using gzip
  config.middleware.use Rack::Deflater
end