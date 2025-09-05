# app/controllers/api/auth/oauth_controller.rb
# OAuth controller for expo-auth-session compatibility (API-only Rails)

require 'net/http'
require 'json'

class Api::Auth::OauthController < ApplicationController
  # Skip authentication for OAuth endpoints
  skip_before_action :authenticate_user!, only: [:authorize, :callback, :token_exchange, :session, :logout, :refresh_token]
  
  # Note: No protect_from_forgery needed in API-only Rails
  # API controllers inherit from ActionController::API, not ActionController::Base

  # ==========================================
  # 🔐 GOOGLE OAUTH AUTHORIZATION
  # ==========================================
  
  def authorize
    # This is the initial OAuth authorization endpoint
    # expo-auth-session will redirect here first
    
    Rails.logger.info "🚀 OAuth authorization request received"
    Rails.logger.info "Parameters: #{params.inspect}"
    
    # Store PKCE challenge and other parameters in session
    # Note: Sessions work in API-only Rails when explicitly enabled
    session[:code_challenge] = params[:code_challenge]
    session[:code_challenge_method] = params[:code_challenge_method] || 'S256'
    session[:state] = params[:state]
    session[:redirect_uri] = params[:redirect_uri]
    session[:platform] = params[:platform] || 'native'
    
    # Build Google OAuth URL
    google_client_id = ENV['GOOGLE_CLIENT_ID']
    unless google_client_id.present?
      return render json: { error: 'Google Client ID not configured' }, status: :internal_server_error
    end
    
    # Our callback URL (where Google will redirect back to)
    callback_uri = "#{request.base_url}/api/auth/callback"
    
    # Generate state parameter for security
    oauth_state = SecureRandom.urlsafe_base64(32)
    session[:oauth_state] = oauth_state
    
    google_auth_url = "https://accounts.google.com/o/oauth2/auth?" + {
      client_id: google_client_id,
      redirect_uri: callback_uri,
      scope: 'openid email profile',
      response_type: 'code',
      state: oauth_state,
      access_type: 'offline',
      prompt: 'select_account'
    }.to_query
    
    Rails.logger.info "🔗 Redirecting to Google: #{google_auth_url}"
    
    # Redirect user to Google OAuth
    redirect_to google_auth_url, allow_other_host: true
  end
  
  # ==========================================
  # 🔄 GOOGLE OAUTH CALLBACK
  # ==========================================
  
  def callback
    # Google redirects back here with authorization code
    Rails.logger.info "📥 OAuth callback received"
    Rails.logger.info "Callback params: #{params.inspect}"
    
    # Validate state parameter
    unless params[:state] == session[:oauth_state]
      Rails.logger.error "❌ Invalid state parameter"
      return render json: { error: 'Invalid state parameter' }, status: :bad_request
    end
    
    # Handle OAuth errors
    if params[:error].present?
      Rails.logger.error "❌ OAuth error: #{params[:error]} - #{params[:error_description]}"
      return render json: { 
        error: params[:error], 
        error_description: params[:error_description] 
      }, status: :bad_request
    end
    
    # Exchange authorization code for Google access token
    begin
      google_tokens = exchange_code_with_google(params[:code])
      user_info = get_google_user_info(google_tokens['access_token'])
      user = find_or_create_user_from_google(user_info)
      
      if user.persisted?
        # Generate your app's JWT tokens
        access_token = generate_jwt_token(user)
        
        # Store authorization code temporarily for token exchange
        session[:temp_auth_code] = SecureRandom.urlsafe_base64(32)
        session[:temp_user_id] = user.id
        session[:temp_access_token] = access_token
        
        # Redirect back to the app with authorization code
        original_redirect_uri = session[:redirect_uri]
        final_redirect_url = "#{original_redirect_uri}?" + {
          code: session[:temp_auth_code],
          state: session[:state]
        }.to_query
        
        Rails.logger.info "✅ OAuth successful, redirecting to: #{final_redirect_url}"
        redirect_to final_redirect_url, allow_other_host: true
      else
        Rails.logger.error "❌ User creation failed: #{user.errors.full_messages}"
        render json: { error: 'User creation failed', details: user.errors.full_messages }, status: :unprocessable_entity
      end
    rescue => e
      Rails.logger.error "❌ OAuth callback error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: 'Authentication failed', details: e.message }, status: :internal_server_error
    end
  end
  
  # ==========================================
  # 🔄 TOKEN EXCHANGE (for expo-auth-session)
  # ==========================================
  
  def token_exchange
    # expo-auth-session calls this to exchange the authorization code for tokens
    Rails.logger.info "🔄 Token exchange request"
    Rails.logger.info "Request params: #{params.inspect}"
    
    code = params[:code]
    platform = params[:platform] || 'native'
    
    unless code.present?
      return render json: { error: 'Authorization code required' }, status: :bad_request
    end
    
    # Verify the temporary authorization code
    unless code == session[:temp_auth_code]
      Rails.logger.error "❌ Invalid authorization code: #{code}"
      return render json: { error: 'Invalid authorization code' }, status: :unauthorized
    end
    
    # Get stored user and token
    user_id = session[:temp_user_id]
    access_token = session[:temp_access_token]
    
    unless user_id && access_token
      Rails.logger.error "❌ No stored user data found"
      return render json: { error: 'No authentication data found' }, status: :unauthorized
    end
    
    user = User.find(user_id)
    refresh_token = generate_refresh_token(user)
    
    # Clear temporary session data
    session.delete(:temp_auth_code)
    session.delete(:temp_user_id)
    session.delete(:temp_access_token)
    
    Rails.logger.info "✅ Token exchange successful for user: #{user.email}"
    
    # Return tokens and user data
    render json: {
      accessToken: access_token,
      refreshToken: refresh_token,
      user: serialize_user(user),
      is_new_user: user.created_at > 5.minutes.ago,
      success: true
    }
  end
  
  # ==========================================
  # 📱 SESSION MANAGEMENT
  # ==========================================
  
  def session
    # Get current user session (for web)
    user = current_user_from_session
    
    if user
      render json: serialize_user(user)
    else
      render json: { error: 'No active session' }, status: :unauthorized
    end
  end
  
  def logout
    # Clear session/cookies
    session.clear if session.respond_to?(:clear)
    render json: { success: true, message: 'Logged out successfully' }
  end
  
  def refresh_token
    # Handle token refresh (implement if needed)
    render json: { error: 'Refresh token endpoint not implemented' }, status: :not_implemented
  end
  
  private
  
  # ==========================================
  # 🔧 HELPER METHODS
  # ==========================================
  
  def exchange_code_with_google(authorization_code)
    Rails.logger.info "🔄 Exchanging code with Google"
    
    uri = URI('https://oauth2.googleapis.com/token')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    
    callback_uri = "#{self.request.base_url}/api/auth/callback"
    
    request.body = {
      client_id: ENV['GOOGLE_CLIENT_ID'],
      client_secret: ENV['GOOGLE_CLIENT_SECRET'],
      code: authorization_code,
      grant_type: 'authorization_code',
      redirect_uri: callback_uri
    }.to_query
    
    response = http.request(request)
    
    if response.code == '200'
      JSON.parse(response.body)
    else
      Rails.logger.error "❌ Google token exchange failed: #{response.body}"
      raise "Google token exchange failed: #{response.body}"
    end
  end
  
  def get_google_user_info(access_token)
    Rails.logger.info "📋 Fetching user info from Google"
    
    uri = URI('https://www.googleapis.com/oauth2/v2/userinfo')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{access_token}"
    
    response = http.request(request)
    
    if response.code == '200'
      JSON.parse(response.body)
    else
      Rails.logger.error "❌ Google user info failed: #{response.body}"
      raise "Failed to get Google user info: #{response.body}"
    end
  end
  
  def find_or_create_user_from_google(user_info)
    Rails.logger.info "👤 Finding/creating user: #{user_info['email']}"
    
    user = User.find_by(email: user_info['email'])
    
    if user
      # Update existing user with Google info
      user.update(
        provider: 'google_oauth2',
        uid: user_info['id'],
        google_image_url: user_info['picture']
      )
      Rails.logger.info "✅ Updated existing user: #{user.email}"
    else
      # Create new user
      password = Devise.friendly_token[0, 20]
      user = User.create(
        email: user_info['email'],
        password: password,
        password_confirmation: password,
        first_name: user_info['given_name'] || 'Google',
        last_name: user_info['family_name'] || 'User',
        provider: 'google_oauth2',
        uid: user_info['id'],
        confirmed_at: Time.current,
        google_image_url: user_info['picture']
      )
      
      # Add default role if user has roles system
      if user.persisted? && user.respond_to?(:add_role) && user.roles.blank?
        user.add_role(:client)
      end
      
      Rails.logger.info "✅ Created new user: #{user.email}"
    end
    
    user
  end
  
  def generate_jwt_token(user)
    payload = {
      user_id: user.id,
      email: user.email,
      name: user_full_name(user),
      role: user_primary_role(user),
      exp: 24.hours.from_now.to_i
    }
    
    JWT.encode(payload, Rails.application.secret_key_base, 'HS256')
  end
  
  def generate_refresh_token(user)
    payload = {
      user_id: user.id,
      type: 'refresh',
      exp: 30.days.from_now.to_i
    }
    
    JWT.encode(payload, Rails.application.secret_key_base, 'HS256')
  end
  
  def current_user_from_session
    # Try to get user from JWT token in Authorization header
    auth_header = request.headers['Authorization']
    if auth_header&.start_with?('Bearer ')
      token = auth_header.split(' ')[1]
      begin
        decoded = JWT.decode(token, Rails.application.secret_key_base, true, { algorithm: 'HS256' })
        payload = decoded[0]
        return User.find(payload['user_id'])
      rescue JWT::DecodeError, ActiveRecord::RecordNotFound
        nil
      end
    end
    
    # Fallback to session-based authentication
    nil
  end
  
  def serialize_user(user)
    {
      id: user.id,
      email: user.email,
      first_name: user.first_name,
      last_name: user.last_name,
      full_name: user_full_name(user),
      display_name: user_display_name(user),
      google_user: user_is_google_user(user),
      needs_password: user_needs_password(user),
      profile_complete: profile_complete?(user),
      primary_role: user_primary_role(user),
      roles: user_roles(user),
      avatar_url: user_avatar_url(user),
      google_image_url: user.respond_to?(:google_image_url) ? user.google_image_url : nil
    }
  end
  
  # Helper methods that safely handle missing methods
  def user_full_name(user)
    if user.respond_to?(:full_name)
      user.full_name
    else
      "#{user.first_name} #{user.last_name}".strip
    end
  end
  
  def user_display_name(user)
    if user.respond_to?(:display_name)
      user.display_name
    else
      user_full_name(user).present? ? user_full_name(user) : user.email
    end
  end
  
  def user_is_google_user(user)
    if user.respond_to?(:google_user?)
      user.google_user?
    else
      user.provider == 'google_oauth2'
    end
  end
  
  def user_needs_password(user)
    if user.respond_to?(:needs_password?)
      user.needs_password?
    else
      user.encrypted_password.blank? && user.provider.present?
    end
  end
  
  def user_primary_role(user)
    if user.respond_to?(:primary_role)
      user.primary_role
    elsif user.respond_to?(:roles)
      user.roles.first&.name || 'client'
    else
      'client'
    end
  end
  
  def user_roles(user)
    if user.respond_to?(:roles)
      user.roles.pluck(:name)
    else
      ['client']
    end
  end
  
  def user_avatar_url(user)
    if user.respond_to?(:avatar) && user.avatar.attached?
      url_for(user.avatar)
    elsif user.respond_to?(:google_image_url)
      user.google_image_url
    else
      nil
    end
  end
  
  def profile_complete?(user)
    user.first_name.present? && 
    user.last_name.present? && 
    (user.respond_to?(:phone_number) ? user.phone_number.present? : true)
  end
end