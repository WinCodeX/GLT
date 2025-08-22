# app/services/google_oauth_service.rb
# Service class to handle Google OAuth operations for API-only Rails app

require 'net/http'
require 'json'
require 'uri'

class GoogleOauthService
  include HTTParty
  
  # Google OAuth endpoints
  GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token'.freeze
  GOOGLE_USERINFO_URL = 'https://www.googleapis.com/oauth2/v1/userinfo'.freeze
  GOOGLE_TOKEN_INFO_URL = 'https://oauth2.googleapis.com/tokeninfo'.freeze
  GOOGLE_AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth'.freeze

  def initialize
    @client_id = ENV['GOOGLE_CLIENT_ID'] || Rails.application.credentials.dig(:google_oauth, :client_id)
    @client_secret = ENV['GOOGLE_CLIENT_SECRET'] || Rails.application.credentials.dig(:google_oauth, :client_secret)
    
    unless @client_id.present? && @client_secret.present?
      Rails.logger.error "❌ Google OAuth credentials not configured"
      raise StandardError, "Google OAuth credentials not configured"
    end
  end

  # ===========================================
  # 🔗 GENERATE OAUTH URL
  # ===========================================

  def generate_auth_url(redirect_uri, state = nil)
    params = {
      client_id: @client_id,
      redirect_uri: redirect_uri,
      scope: 'email profile openid',
      response_type: 'code',
      access_type: 'offline',
      prompt: 'select_account'
    }
    
    params[:state] = state if state.present?
    
    uri = URI(GOOGLE_AUTH_URL)
    uri.query = URI.encode_www_form(params)
    uri.to_s
  end

  # ===========================================
  # 🔄 EXCHANGE CODE FOR TOKENS
  # ===========================================

  def exchange_code_for_tokens(code, redirect_uri)
    Rails.logger.info "🔄 Exchanging OAuth code for tokens"
    
    begin
      response = HTTParty.post(GOOGLE_TOKEN_URL, 
        body: {
          client_id: @client_id,
          client_secret: @client_secret,
          code: code,
          grant_type: 'authorization_code',
          redirect_uri: redirect_uri
        },
        headers: {
          'Content-Type' => 'application/x-www-form-urlencoded'
        },
        timeout: 10
      )

      if response.success?
        tokens = JSON.parse(response.body)
        
        # Get user info using access token
        user_info_result = get_user_info(tokens['access_token'])
        
        if user_info_result[:success]
          Rails.logger.info "✅ Successfully exchanged code for tokens"
          {
            success: true,
            tokens: tokens,
            user_info: user_info_result[:user_info]
          }
        else
          Rails.logger.error "❌ Failed to get user info after token exchange"
          {
            success: false,
            error: user_info_result[:error],
            code: 'user_info_failed'
          }
        end
      else
        error_data = JSON.parse(response.body) rescue {}
        error_message = error_data['error_description'] || error_data['error'] || 'Token exchange failed'
        
        Rails.logger.error "❌ Token exchange failed: #{error_message}"
        {
          success: false,
          error: error_message,
          code: 'token_exchange_failed'
        }
      end

    rescue StandardError => e
      Rails.logger.error "❌ Token exchange error: #{e.message}"
      {
        success: false,
        error: "Token exchange failed: #{e.message}",
        code: 'exchange_error'
      }
    end
  end

  # ===========================================
  # 🔍 VALIDATE ID TOKEN
  # ===========================================

  def validate_id_token(id_token)
    Rails.logger.info "🔍 Validating Google ID token"
    
    begin
      response = HTTParty.get(GOOGLE_TOKEN_INFO_URL, 
        query: { id_token: id_token },
        timeout: 10
      )

      if response.success?
        token_info = JSON.parse(response.body)
        
        # Verify the token is for our app
        if token_info['aud'] != @client_id
          Rails.logger.error "❌ ID token audience mismatch"
          return {
            success: false,
            error: 'Token not issued for this application',
            code: 'audience_mismatch'
          }
        end

        # Check if token is expired
        if token_info['exp'].to_i < Time.current.to_i
          Rails.logger.error "❌ ID token expired"
          return {
            success: false,
            error: 'Token has expired',
            code: 'token_expired'
          }
        end

        Rails.logger.info "✅ ID token validated successfully"
        {
          success: true,
          user_info: format_user_info_from_token(token_info)
        }
      else
        error_data = JSON.parse(response.body) rescue {}
        error_message = error_data['error_description'] || 'Invalid ID token'
        
        Rails.logger.error "❌ ID token validation failed: #{error_message}"
        {
          success: false,
          error: error_message,
          code: 'invalid_id_token'
        }
      end

    rescue StandardError => e
      Rails.logger.error "❌ ID token validation error: #{e.message}"
      {
        success: false,
        error: "Token validation failed: #{e.message}",
        code: 'validation_error'
      }
    end
  end

  # ===========================================
  # 🔍 VALIDATE ACCESS TOKEN
  # ===========================================

  def validate_access_token(access_token)
    Rails.logger.info "🔍 Validating Google access token"
    
    begin
      user_info_result = get_user_info(access_token)
      
      if user_info_result[:success]
        Rails.logger.info "✅ Access token validated successfully"
        user_info_result
      else
        Rails.logger.error "❌ Access token validation failed"
        {
          success: false,
          error: user_info_result[:error] || 'Invalid access token',
          code: 'invalid_access_token'
        }
      end

    rescue StandardError => e
      Rails.logger.error "❌ Access token validation error: #{e.message}"
      {
        success: false,
        error: "Token validation failed: #{e.message}",
        code: 'validation_error'
      }
    end
  end

  # ===========================================
  # 👤 GET USER INFO
  # ===========================================

  def get_user_info(access_token)
    Rails.logger.info "👤 Fetching user info from Google"
    
    begin
      response = HTTParty.get(GOOGLE_USERINFO_URL,
        headers: {
          'Authorization' => "Bearer #{access_token}"
        },
        timeout: 10
      )

      if response.success?
        user_data = JSON.parse(response.body)
        
        Rails.logger.info "✅ User info retrieved for: #{user_data['email']}"
        {
          success: true,
          user_info: format_user_info(user_data)
        }
      else
        error_message = "Failed to get user info: #{response.code}"
        Rails.logger.error "❌ #{error_message}"
        {
          success: false,
          error: error_message
        }
      end

    rescue StandardError => e
      Rails.logger.error "❌ User info fetch error: #{e.message}"
      {
        success: false,
        error: "Failed to fetch user info: #{e.message}"
      }
    end
  end

  # ===========================================
  # 🔄 REFRESH ACCESS TOKEN
  # ===========================================

  def refresh_access_token(refresh_token)
    Rails.logger.info "🔄 Refreshing access token"
    
    begin
      response = HTTParty.post(GOOGLE_TOKEN_URL,
        body: {
          client_id: @client_id,
          client_secret: @client_secret,
          refresh_token: refresh_token,
          grant_type: 'refresh_token'
        },
        headers: {
          'Content-Type' => 'application/x-www-form-urlencoded'
        },
        timeout: 10
      )

      if response.success?
        tokens = JSON.parse(response.body)
        Rails.logger.info "✅ Access token refreshed successfully"
        {
          success: true,
          tokens: tokens
        }
      else
        error_data = JSON.parse(response.body) rescue {}
        error_message = error_data['error_description'] || 'Token refresh failed'
        
        Rails.logger.error "❌ Token refresh failed: #{error_message}"
        {
          success: false,
          error: error_message,
          code: 'refresh_failed'
        }
      end

    rescue StandardError => e
      Rails.logger.error "❌ Token refresh error: #{e.message}"
      {
        success: false,
        error: "Token refresh failed: #{e.message}",
        code: 'refresh_error'
      }
    end
  end

  private

  # ===========================================
  # 🔧 HELPER METHODS
  # ===========================================

  # Format user info from API response
  def format_user_info(user_data)
    {
      google_id: user_data['id'],
      email: user_data['email'],
      name: user_data['name'],
      given_name: user_data['given_name'],
      family_name: user_data['family_name'],
      picture: user_data['picture'],
      verified_email: user_data['verified_email']
    }
  end

  # Format user info from token info (ID token validation)
  def format_user_info_from_token(token_info)
    {
      google_id: token_info['sub'],
      email: token_info['email'],
      name: token_info['name'],
      given_name: token_info['given_name'],
      family_name: token_info['family_name'],
      picture: token_info['picture'],
      verified_email: token_info['email_verified'] == 'true'
    }
  end

  # Check if credentials are configured
  def credentials_configured?
    @client_id.present? && @client_secret.present?
  end

  # Log HTTP request details (for debugging)
  def log_request(method, url, params = {})
    Rails.logger.debug "🌐 #{method.upcase} #{url}"
    Rails.logger.debug "📋 Params: #{params.except(:client_secret).inspect}" if params.any?
  end

  # Handle HTTP errors gracefully
  def handle_http_error(response, context = 'HTTP request')
    error_body = response.body rescue 'No response body'
    Rails.logger.error "❌ #{context} failed: #{response.code} - #{error_body}"
    
    {
      success: false,
      error: "#{context} failed with status #{response.code}",
      code: "http_#{response.code}"
    }
  end
end