# app/controllers/api/v1/omniauth_callbacks_controller.rb
# Fixed OAuth controller for API-only Rails with JWT authentication

module Api
  module V1
    class OmniauthCallbacksController < ApplicationController
      # Inherit from ApplicationController instead of Devise::OmniauthCallbacksController
      # This avoids issues with Devise's full Rails assumptions
      
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
            # Mark user as online
            @user.mark_online! if @user.respond_to?(:mark_online!)
            
            # Log successful authentication
            Rails.logger.info "✅ Successfully authenticated user: #{@user.email} via Google OAuth"
            
            # For API mode, we'll redirect to a success page or return JSON
            # You can customize this based on your needs
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
              'avatar_attached' : (user.respond_to?(:google_image_url) ? user.google_image_url : nil)
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