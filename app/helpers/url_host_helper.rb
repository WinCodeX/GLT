# app/helpers/url_host_helper.rb
require 'net/http'
require 'uri'

module UrlHostHelper
  def first_available_host
    Rails.configuration.x.avatar_hosts.each do |host|
      return host if url_reachable?(host)
    end
    nil
  end

  def url_reachable?(host)
    uri = URI.join(host, "/") # Only checks root
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 0.3, read_timeout: 0.5) do |http|
      http.head(uri.request_uri)
    end
    response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
  rescue StandardError
    false
  end
end