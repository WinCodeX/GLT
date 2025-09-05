# app/controllers/api/auth/oauth_controller.rb
# Fixed syntax errors and improved error handling

class Api::Auth::OauthController < ApplicationController
  skip_before_action :authenticate_user!, only: [:authorize, :callback, :token_exchange, :session, :logout, :refresh_token]
  
  def authorize
    Rails.logger.info "OAuth authorize endpoint accessed"
    Rails.logger.info "Params: #{params.inspect}"
    
    begin
      # Check if sessions are working
      unless session_available?
        render json: { 
          error: 'Sessions not available',
          message: 'API-only Rails session configuration issue' 
        }, status: :internal_server_error
        return
      end
      
      # Check environment variables
      unless oauth_configured?
        render json: { 
          error: 'OAuth not configured', 
          missing: missing_env_vars 
        }, status: :internal_server_error
        return
      end
      
      # Store parameters safely
      store_oauth_params
      
      # Build Google OAuth URL
      google_auth_url = build_google_auth_url
      
      Rails.logger.info "Redirecting to Google: #{google_auth_url}"
      
      # Only redirect - no render after this point
      redirect_to google_auth_url, allow_other_host: true
      
    rescue => e
      Rails.logger.error "OAuth authorize error: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      
      # Only render error if we haven't already rendered/redirected
      unless performed?
        render json: { 
          error: 'OAuth authorization failed',
          details: e.message,
          type: e.class.name
        }, status: :internal_server_error
      end
    end
  end
  
  def callback
    Rails.logger.info "OAuth callback received"
    Rails.logger.info "Callback params: #{params.except(:controller, :action).inspect}"
    
    # Validate state parameter
    if params[:state] != session['oauth_state']
      render json: { 
        error: 'Invalid state parameter',
        received_state: params[:state],
        expected_state: session['oauth_state']
      }, status: :bad_request
      return
    end
    
    # Handle OAuth errors from Google
    if params[:error].present?
      render json: { 
        error: 'Google OAuth error',
        error_type: params[:error],
        error_description: params[:error_description]
      }, status: :bad_request
      return
    end
    
    # Success response
    render json: { 
      message: "OAuth callback successful",
      code: params[:code].present? ? "received" : "missing",
      state: "validated"
    }
  end
  
  def token_exchange
    Rails.logger.info "Token exchange request"
    render json: { 
      message: "Token exchange endpoint working",
      method: request.method,
      content_type: request.content_type
    }
  end
  
  def session
    # Get session ID safely
    session_id = get_session_id
    
    render json: { 
      message: "Session endpoint working",
      session_available: session_available?,
      session_id: session_id
    }
  end
  
  def logout
    begin
      session.clear if session.respond_to?(:clear)
      message = "Logout successful - session cleared"
    rescue => e
      Rails.logger.warn "Session clear failed: #{e.message}"
      message = "Logout completed - session clear failed"
    end
    
    render json: { 
      message: message,
      timestamp: Time.current
    }
  end
  
  def refresh_token
    render json: { 
      message: "Refresh token endpoint working",
      note: "Not implemented yet"
    }
  end
  
  private
  
  # Check if sessions are available and working
  def session_available?
    session.respond_to?(:[]) && session.respond_to?(:[]=)
  rescue => e
    Rails.logger.error "Session availability check failed: #{e.message}"
    false
  end
  
  # Get session ID safely
  def get_session_id
    session.id
  rescue => e
    Rails.logger.warn "Could not get session ID: #{e.message}"
    "unavailable"
  end
  
  # Store OAuth parameters safely
  def store_oauth_params
    # Use string keys to avoid type conversion issues
    session['code_challenge'] = params[:code_challenge].to_s if params[:code_challenge]
    session['code_challenge_method'] = params[:code_challenge_method].to_s || 'S256'
    session['state'] = params[:state].to_s if params[:state]
    session['redirect_uri'] = params[:redirect_uri].to_s if params[:redirect_uri]
    session['platform'] = params[:platform].to_s || 'native'
    
    # Generate and store OAuth state
    oauth_state = SecureRandom.urlsafe_base64(32)
    session['oauth_state'] = oauth_state
    
    Rails.logger.info "OAuth params stored in session"
  end
  
  # Check if OAuth is properly configured
  def oauth_configured?
    ENV['GOOGLE_CLIENT_ID'].present? && ENV['GOOGLE_CLIENT_SECRET'].present?
  end
  
  # Build Google OAuth authorization URL
  def build_google_auth_url
    google_client_id = ENV['GOOGLE_CLIENT_ID']
    callback_uri = "#{request.base_url}/api/auth/callback"
    oauth_state = session['oauth_state']
    
    "https://accounts.google.com/o/oauth2/auth?" + {
      client_id: google_client_id,
      redirect_uri: callback_uri,
      scope: 'openid email profile',
      response_type: 'code',
      state: oauth_state,
      access_type: 'offline',
      prompt: 'select_account'
    }.to_query
  end
  
  # Get list of missing environment variables
  def missing_env_vars
    missing = []
    missing << 'GOOGLE_CLIENT_ID' unless ENV['GOOGLE_CLIENT_ID'].present?
    missing << 'GOOGLE_CLIENT_SECRET' unless ENV['GOOGLE_CLIENT_SECRET'].present?
    missing << 'DEVISE_JWT_SECRET_KEY' unless ENV['DEVISE_JWT_SECRET_KEY'].present?
    missing
  end
end