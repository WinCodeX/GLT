# app/controllers/api/v1/omniauth_callbacks_controller.rb - API-only version

module Api
  module V1
    class OmniauthCallbacksController < Devise::OmniauthCallbacksController
      respond_to :json

      # ===========================================
      # 🔐 GOOGLE OAUTH CALLBACK HANDLER
      # ===========================================

      def google_oauth2
        Rails.logger.info "🔐 Google OAuth2 callback received"
        Rails.logger.info "Auth hash email: #{request.env['omniauth.auth']&.info&.email}"

        begin
          # Get the auth hash from omniauth
          auth_hash = request.env['omniauth.auth']
          
          unless auth_hash
            Rails.logger.error "No auth hash found in callback"
            handle_auth_failure('No authentication data received')
            return
          end

          # Find or create user from Google OAuth
          @user = User.from_omniauth(auth_hash)
          
          if @user.persisted?
            # User successfully created/found - let devise-jwt handle sign in
            sign_in(@user)
            @user.mark_online!
            
            Rails.logger.info "✅ Successfully signed in user: #{@user.email}"
            
            render json: {
              status: 'success',
              message: 'Successfully authenticated with Google',
              user: serialize_user(@user),
              auth_method: 'google_oauth2'
            }, status: :ok
            
          else
            # User creation failed
            Rails.logger.error "❌ User creation failed: #{@user.errors.full_messages}"
            handle_auth_failure("Account creation failed: #{@user.errors.full_messages.join(', ')}")
          end

        rescue => e
          Rails.logger.error "❌ Google OAuth callback error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          handle_auth_failure("Authentication error: #{e.message}")
        end
      end

      # ===========================================
      # 🚫 OAUTH FAILURE HANDLER
      # ===========================================

      def failure
        error_kind = params[:error_reason] || params[:error] || 'unknown'
        error_message = params[:error_description] || 'Authentication failed'
        
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

      def handle_auth_failure(message)
        Rails.logger.error "❌ Auth failure: #{message}"
        
        render json: {
          status: 'error',
          message: message,
          code: 'authentication_failed'
        }, status: :unprocessable_entity
      end

      # Serialize user for JSON response
      def serialize_user(user)
        if defined?(UserSerializer)
          UserSerializer.new(user).as_json
        else
          user.as_json(
            only: [:id, :email, :first_name, :last_name, :phone_number],
            methods: [:full_name, :display_name, :primary_role, :google_user?, :needs_password?]
          ).tap do |json|
            # Add OAuth specific fields
            json.merge!(
              'google_user' => user.google_user?,
              'needs_password' => user.needs_password?,
              'profile_complete' => profile_complete?(user),
              'setup_required' => setup_required?(user)
            )
          end
        end
      end

      def profile_complete?(user)
        user.first_name.present? && 
        user.last_name.present? && 
        user.phone_number.present?
      end

      def setup_required?(user)
        return false unless user.google_user?
        
        !profile_complete?(user) || 
        (user.needs_password? && user.created_at > 1.hour.ago)
      end
    end
  end
end