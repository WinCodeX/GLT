require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true

  # Enable serving static files from public/, but let CDN/reverse proxy handle it primarily
  config.public_file_server.enabled = ENV['RAILS_SERVE_STATIC_FILES'].present?
  
  # Configure static file serving with proper headers for performance
  if config.public_file_server.enabled
    config.public_file_server.headers = {
      'Cache-Control' => 'public, max-age=31536000' # 1 year cache for static assets
    }
  end

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  # config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # for NGINX

  # ==========================================
  # 🗄️ STORAGE CONFIGURATION - ONLY CHANGE THIS LINE
  # ==========================================
  
  # Use Cloudflare R2 storage instead of local (ONLY CHANGE FOR R2 FIX)
  config.active_storage.service = :cloudflare

  # ==========================================
  # 🔧 URL & HOST CONFIGURATION
  # ==========================================
  Rails.application.routes.default_url_options[:host] = 'https://glt-53x8.onrender.com'

  # 📸 AVATAR HOSTS CONFIGURATION (Updated for R2)
  config.x.avatar_hosts = [
    'https://glt-53x8.onrender.com',
    ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 'https://pub-63612670c2d64075820ce8724feff8ea.r2.dev'
  ]

  # ==========================================
  # 🚀 PERFORMANCE & CACHING
  # ==========================================
  
  # Use Redis for caching in production (recommended)
  # If you have Redis available, uncomment this:
  # config.cache_store = :redis_cache_store, {
  #   url: ENV['REDIS_URL'] || 'redis://localhost:6379/1',
  #   expires_in: 1.hour,
  #   race_condition_ttl: 10.seconds
  # }
  
  # Fallback to memory cache if Redis not available
  config.cache_store = :memory_store, { 
    size: 128 * 1024 * 1024,
    expires_in: 1.hour 
  }

  # Enable Active Storage optimizations for R2
  config.active_storage.variant_processor = :mini_magick

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
  # 📱 CORS CONFIGURATION (for Expo Go/React Native) - RESTORE ORIGINAL
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
  # 🔌 ACTIONCABLE CONFIGURATION - CRITICAL FIX
  # ==========================================
  
  # CRITICAL: Set ActionCable adapter explicitly
  config.action_cable.adapter = :redis
  
  # ActionCable Redis URL
  config.action_cable.url = 'wss://glt-53x8.onrender.com/cable'
  
  # Allowed origins for ActionCable
  config.action_cable.allowed_request_origins = [
    'https://glt-53x8.onrender.com',
    'http://localhost:8081',
    'exp://192.168.100.73:8081',
    /^https:\/\/.*\.expo\.dev$/,
    /^https:\/\/.*\.exp\.direct$/,
    /^exp:\/\/.*$/,
    /^http:\/\/localhost:*/
  ]
  
  # ActionCable mount path
  config.action_cable.mount_path = '/cable'
  
  # ActionCable worker pool size
  config.action_cable.worker_pool_size = 4
  
  # ActionCable disable request forgery protection (needed for mobile apps)
  config.action_cable.disable_request_forgery_protection = true

  # ==========================================
  # 🔧 ADDITIONAL PERFORMANCE OPTIMIZATIONS
  # ==========================================
  
  # Compress responses using gzip
  config.middleware.use Rack::Deflater

  # Set timeouts for better performance
  config.force_ssl = true
  
  # Configure session store (if needed)
  # config.session_store :disabled

  # ==========================================
  # 📊 MONITORING & ANALYTICS
  # ==========================================
  
  # Enable server timing for performance monitoring
  # config.server_timing = true

  # Configure error reporting (add your service)
  # config.middleware.use ExceptionNotification::Rack,
  #   email: {
  #     email_prefix: '[GLT API Error] ',
  #     sender_address: %{"GLT API" <noreply@glt-53x8.onrender.com>},
  #     exception_recipients: %w{admin@glt.com}
  #   }

  # ==========================================
  # 🌍 INTERNATIONALIZATION
  # ==========================================
  
  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations in production
  config.active_support.report_deprecations = false

  # ==========================================
  # 🗄️ DATABASE CONFIGURATION
  # ==========================================
  
  # Do not dump schema after migrations in production
  config.active_record.dump_schema_after_migration = false

  # ==========================================
  # ⚡ BACKGROUND JOBS CONFIGURATION
  # ==========================================
  
  # Use a real queuing backend for Active Job
  # config.active_job.queue_adapter = :sidekiq
  # config.active_job.queue_name_prefix = "glt_api_production"
end