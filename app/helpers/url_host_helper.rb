# app/helpers/url_host_helper.rb - FIXED: Resilient host checking
module UrlHostHelper
  def first_available_host
    # In production, always use the default host to avoid unnecessary overhead
    if Rails.env.production?
      default_host = Rails.application.routes.default_url_options[:host]
      return default_host if default_host.present?
      return request.host_with_port if respond_to?(:request) && request.present?
      return 'https://glt-53x8.onrender.com' # Fallback for production
    end
    
    # In development/test, try to find the best available host
    avatar_hosts = Rails.configuration.x.avatar_hosts || []
    
    # Add some sensible defaults if none configured
    if avatar_hosts.empty?
      avatar_hosts = [
        'http://192.168.100.73:3000',
        'http://192.168.162.106:3000',
        'http://localhost:3000',
        'https://glt-53x8.onrender.com'
      ]
    end
    
    # Check hosts in order, but with caching to avoid repeated HTTP calls
    avatar_hosts.each do |host|
      if host_reachable_cached?(host)
        return host
      end
    end
    
    # Fallback strategies
    fallback_host = get_fallback_host
    Rails.logger.warn "No avatar hosts reachable, using fallback: #{fallback_host}"
    fallback_host
  end

  private

  def get_fallback_host
    # Try to get from request if available
    if respond_to?(:request) && request.present?
      begin
        return "#{request.protocol}#{request.host_with_port}"
      rescue => e
        Rails.logger.debug "Could not get host from request: #{e.message}"
      end
    end
    
    # Try default URL options
    default_host = Rails.application.routes.default_url_options[:host]
    if default_host.present?
      protocol = Rails.application.routes.default_url_options[:protocol] || 'http'
      return "#{protocol}://#{default_host}"
    end
    
    # Last resort fallbacks
    if Rails.env.production?
      'https://glt-53x8.onrender.com'
    else
      'http://localhost:3000'
    end
  end

  def host_reachable_cached?(host)
    # Cache host reachability for 60 seconds to avoid repeated HTTP calls
    cache_key = "host_reachable_#{Digest::MD5.hexdigest(host)}"
    
    begin
      Rails.cache.fetch(cache_key, expires_in: 60.seconds) do
        url_reachable?(host)
      end
    rescue => e
      Rails.logger.debug "Error checking cached host reachability for #{host}: #{e.message}"
      false
    end
  end

  def url_reachable?(host)
    return false if host.blank?
    
    begin
      uri = URI.parse(host)
      
      # Ensure we have a valid URI
      return false unless uri.host.present?
      
      # Set default port if not specified
      port = uri.port || (uri.scheme == 'https' ? 443 : 80)
      
      # Very quick connection test
      response = Net::HTTP.start(
        uri.host, 
        port,
        open_timeout: 0.5,    # Very short timeout
        read_timeout: 0.5,    # Very short timeout
        use_ssl: uri.scheme == 'https'
      ) do |http|
        # Just try a HEAD request to root
        http.head('/')
      end
      
      # Consider 2xx, 3xx, 4xx as "reachable" (server is responding)
      # Only 5xx or network errors are considered unreachable
      response.code.to_i < 500
      
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      Rails.logger.debug "Host #{host} timeout: #{e.message}"
      false
    rescue Errno::ECONNREFUSED => e
      Rails.logger.debug "Host #{host} connection refused: #{e.message}"
      false
    rescue Errno::EHOSTUNREACH => e
      Rails.logger.debug "Host #{host} unreachable: #{e.message}"
      false
    rescue SocketError => e
      Rails.logger.debug "Host #{host} socket error: #{e.message}"
      false
    rescue URI::InvalidURIError => e
      Rails.logger.debug "Invalid URI #{host}: #{e.message}"
      false
    rescue StandardError => e
      Rails.logger.debug "Host #{host} check failed: #{e.class} - #{e.message}"
      false
    end
  end
end