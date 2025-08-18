module UrlHostHelper
  def first_available_host
    # In production, always use the default host
    return Rails.application.routes.default_url_options[:host] if Rails.env.production?
    
    # In development, try to find a reachable host
    avatar_hosts = Rails.configuration.x.avatar_hosts || []
    
    # Check hosts in order, but with caching to avoid repeated HTTP calls
    avatar_hosts.each do |host|
      if host_reachable_cached?(host)
        return host
      end
    end
    
    # Fallback to default host if none are reachable
    Rails.application.routes.default_url_options[:host] || 'http://localhost:3000'
  end

  private

  def host_reachable_cached?(host)
    # Cache host reachability for 30 seconds to avoid repeated HTTP calls
    cache_key = "host_reachable_#{host}"
    
    Rails.cache.fetch(cache_key, expires_in: 30.seconds) do
      url_reachable?(host)
    end
  end

  def url_reachable?(host)
    uri = URI.join(host, "/")
    response = Net::HTTP.start(uri.host, uri.port, 
                              open_timeout: 0.3, 
                              read_timeout: 0.5,
                              use_ssl: uri.scheme == 'https') do |http|
      http.head(uri.request_uri)
    end
    response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
  rescue StandardError => e
    Rails.logger.debug "Host #{host} unreachable: #{e.message}"
    false
  end
end