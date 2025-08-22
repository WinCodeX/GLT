# app/helpers/url_host_helper.rb - Optimized for performance and reliability

module UrlHostHelper
  # Cache key for host resolution
  HOST_CACHE_KEY = 'app_host_resolution'.freeze
  HOST_CACHE_DURATION = 5.minutes

  # ===========================================
  # 🚀 PRIMARY HOST RESOLUTION (Optimized)
  # ===========================================

  def first_available_host
    # Use cached result for performance
    Rails.cache.fetch(HOST_CACHE_KEY, expires_in: HOST_CACHE_DURATION) do
      resolve_primary_host
    end
  end

  # ===========================================
  # 🎯 ENVIRONMENT-SPECIFIC HOST RESOLUTION
  # ===========================================

  def resolve_primary_host
    case Rails.env
    when 'production'
      production_host
    when 'staging'
      staging_host
    when 'development'
      development_host
    when 'test'
      test_host
    else
      fallback_host
    end
  end

  # Production host resolution (deterministic, no network calls)
  def production_host
    # Priority order for production hosts
    configured_production_host ||
    env_production_host ||
    request_host_if_secure ||
    default_production_host
  end

  # Development host resolution (smart but fast)
  def development_host
    # Try request host first (most reliable in dev)
    current_request_host ||
    configured_development_host ||
    env_development_host ||
    smart_localhost_detection ||
    default_development_host
  end

  # Staging host resolution
  def staging_host
    configured_staging_host ||
    env_staging_host ||
    request_host_if_available ||
    default_staging_host
  end

  # Test environment host
  def test_host
    ENV['TEST_HOST'] || 'test.host:3000'
  end

  # ===========================================
  # 🔧 HOST DETECTION STRATEGIES
  # ===========================================

  private

  # Get configured production host
  def configured_production_host
    Rails.application.routes.default_url_options[:host]&.then do |host|
      port = Rails.application.routes.default_url_options[:port]
      protocol = Rails.application.routes.default_url_options[:protocol] || 'https'
      
      build_host_url(host, port, protocol)
    end
  end

  # Get production host from environment
  def env_production_host
    ENV['PRODUCTION_HOST'] || ENV['APP_HOST'] || ENV['HOST']
  end

  # Get request host only if using HTTPS (security check)
  def request_host_if_secure
    return nil unless request_available?
    return nil unless request.ssl? || Rails.env.development?
    
    current_request_host
  end

  # Default production host
  def default_production_host
    'https://glt-53x8.onrender.com' # Your production domain
  end

  # Get configured development host
  def configured_development_host
    Rails.application.config.action_mailer&.default_url_options&.dig(:host)&.then do |host|
      port = Rails.application.config.action_mailer.default_url_options[:port] || 3000
      "http://#{host}:#{port}"
    end
  end

  # Get development host from environment
  def env_development_host
    ENV['DEVELOPMENT_HOST'] || ENV['DEV_HOST']
  end

  # Smart localhost detection for development
  def smart_localhost_detection
    # Try to detect the best localhost address
    if defined?(Rails::Server) && Rails::Server.respond_to?(:new)
      # Get the current server configuration if available
      server_host = detect_rails_server_host
      return server_host if server_host
    end
    
    # Check for common development host patterns
    detect_common_dev_hosts
  end

  # Default development host
  def default_development_host
    'http://localhost:3000'
  end

  # Get staging host from configuration
  def configured_staging_host
    Rails.application.config.staging_host if Rails.application.config.respond_to?(:staging_host)
  end

  # Get staging host from environment
  def env_staging_host
    ENV['STAGING_HOST'] || ENV['STAGE_HOST']
  end

  # Default staging host
  def default_staging_host
    'https://staging.glt-53x8.onrender.com' # Your staging domain
  end

  # ===========================================
  # 🌐 REQUEST-BASED HOST DETECTION
  # ===========================================

  # Get host from current request if available
  def current_request_host
    return nil unless request_available?
    
    begin
      protocol = request.ssl? ? 'https' : 'http'
      host = request.host
      port = request.port
      
      # Build URL with proper port handling
      if standard_port?(port, request.ssl?)
        "#{protocol}://#{host}"
      else
        "#{protocol}://#{host}:#{port}"
      end
    rescue => e
      Rails.logger.debug "Error getting request host: #{e.message}"
      nil
    end
  end

  # Get request host if available (less strict)
  def request_host_if_available
    current_request_host
  rescue
    nil
  end

  # Check if request is available
  def request_available?
    respond_to?(:request) && request.present?
  rescue
    false
  end

  # ===========================================
  # 🔍 SMART HOST DETECTION
  # ===========================================

  # Detect Rails server host configuration
  def detect_rails_server_host
    return nil unless Rails.env.development?
    
    # Try to get server options from Rails server
    begin
      # Check if we can access the current server instance
      if defined?(Rails.application.server) && Rails.application.server
        server = Rails.application.server
        host = server.options[:Host] || 'localhost'
        port = server.options[:Port] || 3000
        return "http://#{host}:#{port}"
      end
    rescue => e
      Rails.logger.debug "Could not detect Rails server host: #{e.message}"
    end
    
    nil
  end

  # Detect common development host patterns
  def detect_common_dev_hosts
    # Common development hosts in order of preference
    common_hosts = [
      'http://localhost:3000',
      'http://127.0.0.1:3000',
      'http://0.0.0.0:3000'
    ]
    
    # In development, we can try a quick check of the process
    current_port = detect_current_rails_port
    if current_port && current_port != 3000
      common_hosts.unshift("http://localhost:#{current_port}")
    end
    
    common_hosts.first
  end

  # Detect current Rails server port
  def detect_current_rails_port
    return nil unless Rails.env.development?
    
    # Try to detect from various sources
    ENV['PORT']&.to_i ||
    detect_port_from_server_config ||
    3000 # Default Rails port
  end

  # Detect port from server configuration
  def detect_port_from_server_config
    return nil unless defined?(Rails.application.server)
    
    begin
      Rails.application.server&.options&.dig(:Port)
    rescue
      nil
    end
  end

  # ===========================================
  # 🛠️ UTILITY METHODS
  # ===========================================

  # Build complete host URL
  def build_host_url(host, port = nil, protocol = nil)
    return host if host.start_with?('http://', 'https://')
    
    protocol ||= (Rails.env.production? ? 'https' : 'http')
    use_ssl = protocol == 'https'
    
    if port && !standard_port?(port, use_ssl)
      "#{protocol}://#{host}:#{port}"
    else
      "#{protocol}://#{host}"
    end
  end

  # Check if port is standard for the protocol
  def standard_port?(port, ssl = false)
    port_int = port.to_i
    ssl ? port_int == 443 : port_int == 80
  end

  # Fallback host for unknown environments
  def fallback_host
    Rails.env.production? ? default_production_host : default_development_host
  end

  # ===========================================
  # 🎯 PUBLIC CONVENIENCE METHODS
  # ===========================================

  public

  # Get host with protocol
  def host_with_protocol(force_ssl: nil)
    host = first_available_host
    return host if host.start_with?('http://', 'https://')
    
    protocol = determine_protocol(force_ssl)
    "#{protocol}://#{host}"
  end

  # Get just the hostname without protocol/port
  def hostname_only
    host = first_available_host
    URI.parse(host).host
  rescue URI::InvalidURIError
    host.split('://').last.split(':').first
  rescue
    'localhost'
  end

  # Get port from current host
  def current_port
    host = first_available_host
    URI.parse(host).port
  rescue
    Rails.env.production? ? 443 : 3000
  end

  # Determine if we should use SSL
  def should_use_ssl?
    Rails.env.production? || 
    (request_available? && request.ssl?) ||
    ENV['FORCE_SSL']&.downcase == 'true'
  end

  # Generate complete URL for a path
  def complete_url(path, force_ssl: nil)
    host = host_with_protocol(force_ssl: force_ssl)
    path = "/#{path}" unless path.start_with?('/')
    "#{host}#{path}"
  end

  # ===========================================
  # 🧪 DEVELOPMENT/DEBUG HELPERS
  # ===========================================

  # Get all available host information (for debugging)
  def host_debug_info
    return {} unless Rails.env.development? || Rails.env.test?
    
    {
      resolved_host: first_available_host,
      environment: Rails.env,
      request_host: current_request_host,
      configured_host: configured_production_host || configured_development_host,
      env_host: env_production_host || env_development_host,
      fallback_host: fallback_host,
      cache_key: HOST_CACHE_KEY,
      cached_value: Rails.cache.read(HOST_CACHE_KEY)
    }
  end

  # Clear host cache (useful for development)
  def clear_host_cache!
    Rails.cache.delete(HOST_CACHE_KEY)
  end

  # Refresh host resolution
  def refresh_host!
    clear_host_cache!
    first_available_host
  end

  private

  # Determine protocol to use
  def determine_protocol(force_ssl = nil)
    return 'https' if force_ssl == true
    return 'http' if force_ssl == false
    
    should_use_ssl? ? 'https' : 'http'
  end

  # ===========================================
  # 📱 MOBILE-SPECIFIC OPTIMIZATIONS
  # ===========================================

  # Get host optimized for mobile/API usage
  def api_host
    # For API usage, prefer more reliable/faster hosts
    case Rails.env
    when 'production'
      ENV['API_HOST'] || production_host
    when 'staging'
      ENV['STAGING_API_HOST'] || staging_host
    else
      development_host
    end
  end

  # Get host for avatar/asset serving (can be CDN)
  def asset_host
    ENV['ASSET_HOST'] || 
    ENV['CDN_HOST'] || 
    first_available_host
  end

  # ===========================================
  # 🔒 SECURITY VALIDATIONS
  # ===========================================

  # Validate host for security
  def valid_host?(host)
    return false if host.blank?
    return false if host.length > 253 # RFC limit
    return false if host.match?(/[<>'"\\]/) # Prevent injection
    
    begin
      uri = URI.parse(host.start_with?('http') ? host : "http://#{host}")
      uri.host.present? && uri.host.match?(/\A[a-zA-Z0-9\-\.]+\z/)
    rescue
      false
    end
  end

  # Sanitize host input
  def sanitize_host(host)
    return nil unless valid_host?(host)
    host.strip.downcase
  end
end