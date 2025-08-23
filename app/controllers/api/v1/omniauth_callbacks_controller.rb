# app/controllers/api/v1/omniauth_callbacks_controller.rb
# Fixed OAuth controller for API-only Rails with JWT authentication + Mobile Support

module Api
  module V1
    class OmniauthCallbacksController < ApplicationController
      # Skip CSRF for OAuth callbacks
      skip_before_action :verify_authenticity_token, only: [:google_oauth2, :failure]
      
      respond_to :json

      # ===========================================
      # 🚀 OAUTH INITIALIZATION (for state parameter)
      # ===========================================

      def init
        Rails.logger.info "🚀 Initializing Google OAuth with state parameter"
        
        state = params[:state]
        mobile = params[:mobile] == 'true'
        
        # Store state and mobile flag in session for validation
        session[:oauth_state] = state
        session[:mobile_oauth] = mobile
        
        Rails.logger.info "📝 Stored OAuth state: #{state}, mobile: #{mobile}"
        
        # Redirect to the actual Google OAuth endpoint
        redirect_to "/users/auth/google_oauth2", allow_other_host: true
      end

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
            return handle_oauth_error('No authentication data received', 'missing_auth_hash')
          end

          Rails.logger.info "✅ Auth hash received for email: #{auth_hash.info.email}"
          
          # Find or create user from OAuth data
          @user = User.from_omniauth(auth_hash)
          
          if @user&.persisted?
            # Mark user as online
            @user.mark_online! if @user.respond_to?(:mark_online!)
            
            # Generate JWT token using Devise-JWT
            token = generate_jwt_token(@user)
            
            # Log successful authentication
            Rails.logger.info "✅ Successfully authenticated user: #{@user.email} via Google OAuth"
            
            # Check if this is a mobile request
            if mobile_request?
              # Mobile OAuth - redirect to success URL with parameters
              redirect_to_mobile_success(token, @user)
            else
              # API OAuth - return JSON response
              render json: {
                status: 'success',
                message: 'Successfully authenticated with Google',
                token: token,
                user: serialize_user(@user),
                auth_method: 'google_oauth2',
                is_new_user: @user.created_at > 5.minutes.ago
              }, status: :ok
            end
            
          else
            # User creation/update failed
            error_messages = @user&.errors&.full_messages || ['User creation failed']
            Rails.logger.error "❌ User persistence failed: #{error_messages.join(', ')}"
            
            handle_oauth_error(
              "Account creation failed: #{error_messages.join(', ')}", 
              'user_creation_failed',
              { errors: error_messages }
            )
          end

        rescue StandardError => e
          # Handle any unexpected errors
          Rails.logger.error "❌ OAuth callback error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          handle_oauth_error(
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
        
        if mobile_request?
          # Redirect to mobile error URL
          redirect_to_mobile_error(error_message, error_kind)
        else
          # Return JSON error
          render json: {
            status: 'error',
            message: 'Google authentication failed',
            error: error_kind,
            description: error_message,
            code: 'oauth_failure'
          }, status: :bad_request
        end
      end

      private

      # ===========================================
      # 🔧 HELPER METHODS
      # ===========================================

      # Check if this is a mobile OAuth request
      def mobile_request?
        session[:mobile_oauth] == true || params[:mobile] == 'true'
      end

      # Generate JWT token for the user
      def generate_jwt_token(user)
        # If using devise-jwt, you can generate token like this:
        if defined?(Warden::JWTAuth::UserEncoder)
          # Generate JWT token using devise-jwt
          token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
          token
        elsif user.respond_to?(:generate_jwt)
          # If you have a custom JWT method
          user.generate_jwt
        else
          # Fallback - you'll need to implement this based on your JWT setup
          JWT.encode(
            {
              user_id: user.id,
              email: user.email,
              exp: 30.days.from_now.to_i
            },
            Rails.application.secrets.secret_key_base || Rails.application.secret_key_base
          )
        end
      end

      # Redirect to mobile success URL with parameters
      def redirect_to_mobile_success(token, user)
        base_url = request.base_url
        success_url = "#{base_url}/oauth/mobile/success"
        
        # Prepare user data for URL encoding
        user_data = serialize_user(user).to_json
        is_new_user = user.created_at > 5.minutes.ago
        
        # Build success URL with parameters
        redirect_url = "#{success_url}?" + {
          token: token,
          user: CGI.escape(user_data),
          is_new_user: is_new_user,
          status: 'success'
        }.to_query
        
        Rails.logger.info "🚀 Redirecting mobile OAuth to: #{success_url}"
        redirect_to redirect_url, allow_other_host: true
      end

      # Redirect to mobile error URL
      def redirect_to_mobile_error(message, code)
        base_url = request.base_url
        error_url = "#{base_url}/oauth/mobile/success"
        
        redirect_url = "#{error_url}?" + {
          error: CGI.escape(message),
          error_code: code,
          status: 'error'
        }.to_query
        
        Rails.logger.info "❌ Redirecting mobile OAuth error to: #{error_url}"
        redirect_to redirect_url, allow_other_host: true
      end

      # Handle OAuth errors (mobile vs API)
      def handle_oauth_error(message, code, additional_data = {})
        if mobile_request?
          redirect_to_mobile_error(message, code)
        else
          render json: {
            status: 'error',
            message: message,
            code: code,
            **additional_data
          }, status: :unprocessable_entity
        end
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
              url_for(user.avatar) : (user.respond_to?(:google_image_url) ? user.google_image_url : nil)
          )
        end
      end

      # Check if user profile is complete
      def profile_complete?(user)
        user.first_name.present? && 
        user.last_name.present? && 
        user.phone_number.present?
      end
    end
  end
end