# app/controllers/api/v1/omniauth_callbacks_controller.rb
# Fixed OAuth controller for API-only Rails with JWT authentication

module Api
  module V1
    class OmniauthCallbacksController < Devise::OmniauthCallbacksController
      # Skip CSRF for OAuth callbacks in API mode
      skip_before_action :verify_authenticity_token, if: :devise_controller?
      
      # Don't require authentication for OAuth callbacks
      skip_before_action :authenticate_user!, only: [:google_oauth2, :failure]
      
      respond_to :json

      # ===========================================
      # 🔐 GOOGLE OAUTH CALLBACK HANDLER
      # ===========================================

      def google_oauth2
        Rails.logger.info "🔐 Google OAuth2 callback received"
        
        begin
          # Get auth hash from OmniAuth
          auth_hash = request.env['omniauth.auth']
          
          unless auth_hash.present?
            Rails.logger.error "❌ No auth hash found in OAuth callback"
            return render_oauth_error('No authentication data received', 'missing_auth_hash')
          end

          Rails.logger.info "✅ Auth hash received for email: #{auth_hash.info.email}"
          
          # Find or create user from OAuth data
          @user = User.from_omniauth(auth_hash)
          
          if @user&.persisted?
            # Sign in the user - this will trigger JWT token generation via devise-jwt
            sign_in(@user, event: :authentication)
            
            # Mark user as online
            @user.mark_online! if @user.respond_to?(:mark_online!)
            
            # Log successful authentication
            Rails.logger.info "✅ Successfully authenticated user: #{@user.email} via Google OAuth"
            
            # Return success response with user data
            # JWT token is automatically added to response headers by devise-jwt
            render json: {
              status: 'success',
              message: 'Successfully authenticated with Google',
              user: serialize_user(@user),
              auth_method: 'google_oauth2',
              is_new_user: @user.created_at > 5.minutes.ago
            }, status: :ok
            
          else
            # User creation/update failed
            error_messages = @user&.errors&.full_messages || ['User creation failed']
            Rails.logger.error "❌ User persistence failed: #{error_messages.join(', ')}"
            
            render_oauth_error(
              "Account creation failed: #{error_messages.join(', ')}", 
              'user_creation_failed',
              { errors: error_messages }
            )
          end

        rescue StandardError => e
          # Handle any unexpected errors
          Rails.logger.error "❌ OAuth callback error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          render_oauth_error(
            'Authentication error occurred',
            'oauth_callback_error',
            Rails.env.development? ? { details: e.message } : {}
          )
        end
      end

      # ===========================================
      # 🚫 OAUTH FAILURE HANDLER
      # ===========================================

      def failure
        # Extract error information
        error_kind = params[:error_reason] || params[:error] || 'unknown_error'
        error_message = params[:error_description] || params[:message] || 'Authentication failed'
        
        Rails.logger.error "❌ OAuth failure: #{error_kind} - #{error_message}"
        
        render json: {
          status: 'error',
          message: 'Google authentication failed',
          error: error_kind,
          description: error_message,
          code: 'oauth_failure'
        }, status: :bad_request
      end

      private

      # ===========================================
      # 🔧 HELPER METHODS
      # ===========================================

      # Render standardized OAuth error response
      def render_oauth_error(message, code, additional_data = {})
        render json: {
          status: 'error',
          message: message,
          code: code,
          **additional_data
        }, status: :unprocessable_entity
      end

      # Serialize user data for JSON response
      def serialize_user(user)
        # Use UserSerializer if available, otherwise fallback to basic serialization
        if defined?(UserSerializer)
          UserSerializer.new(user).as_json
        else
          user.as_json(
            only: [:id, :email, :first_name, :last_name, :phone_number, :created_at],
            methods: [:full_name, :display_name, :primary_role]
          ).merge(
            'google_user' => user.google_user?,
            'needs_password' => user.needs_password?,
            'profile_complete' => profile_complete?(user),
            'roles' => user.roles.pluck(:name),
            'avatar_url' => user.avatar.attached? ? 
              url_for(user.avatar) : user.google_image_url
          )
        end
      end

      # Check if user profile is complete
      def profile_complete?(user)
        user.first_name.present? && 
        user.last_name.present? && 
        user.phone_number.present?
      end

      # ===========================================
      # 🔧 DEVISE OVERRIDES FOR API
      # ===========================================

      # Override the default after_omniauth_failure_path_for
      def after_omniauth_failure_path_for(scope)
        # In API mode, we handle failures with JSON responses
        # This method shouldn't be called, but we provide a safe fallback
        api_v1_oauth_failure_path if respond_to?(:api_v1_oauth_failure_path)
      end

      # Override sign_in to work properly with API mode
      def sign_in(user, options = {})
        # Use Devise's sign_in method which will trigger JWT token generation
        super(user, options)
        
        # Additional logging for debugging
        Rails.logger.debug "🔐 User signed in via OAuth: #{user.email}"
        Rails.logger.debug "🎫 JWT token should be in response headers"
      end

      # Ensure we're handling API requests properly  
      def request_format
        request.format.json? ? :json : :html
      end

      # ===========================================
      # 🛡️ SECURITY HELPERS
      # ===========================================

      # Validate the OAuth state parameter if using state
      def validate_oauth_state
        # Add state validation logic here if needed
        # For now, OmniAuth handles this automatically
        true
      end

      # Log security events
      def log_oauth_event(event_type, user_email = nil, additional_info = {})
        Rails.logger.info "🔐 OAuth Event: #{event_type} | User: #{user_email} | IP: #{request.remote_ip} | Info: #{additional_info}"
      end

      # ===========================================
      # 📱 MOBILE APP SPECIFIC HANDLING
      # ===========================================

      # Handle mobile app OAuth redirects
      def handle_mobile_redirect(user, success: true)
        # If this is a mobile app OAuth flow, you might want to redirect
        # to a custom URL scheme instead of returning JSON
        # 
        # Example:
        # if mobile_app_request?
        #   if success
        #     redirect_to "yourapp://oauth/success?token=#{extract_jwt_token}"
        #   else
        #     redirect_to "yourapp://oauth/error?message=#{error_message}"
        #   end
        # end
        
        # For now, we'll stick with JSON responses
        # Implement mobile redirect logic here if needed
      end

      def mobile_app_request?
        # Detect if this is a mobile app OAuth request
        # You can check User-Agent, custom headers, or URL parameters
        request.user_agent&.include?('YourMobileApp') ||
        params[:mobile] == 'true' ||
        request.headers['X-Mobile-App'].present?
      end

      # Extract JWT token from response headers (if you need to redirect with it)
      def extract_jwt_token
        # devise-jwt adds the token to response headers
        # You would need to extract it if redirecting to mobile app
        response.headers['Authorization']&.gsub('Bearer ', '')
      end
    end
  end
end