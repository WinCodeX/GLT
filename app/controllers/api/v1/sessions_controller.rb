# app/controllers/api/v1/sessions_controller.rb - Fixed to work properly with devise-jwt
require 'google-id-token'
require 'open-uri'

module Api
  module V1
    class SessionsController < Devise::SessionsController
      respond_to :json
      
      # ===========================================
      # 🔐 REGULAR LOGIN (FIXED - Using devise-jwt properly)
      # ===========================================

      def create
        self.resource = warden.authenticate!(auth_options)
        
        if resource
          # Let devise-jwt handle token generation through its normal flow
          sign_in(resource_name, resource)
          resource.mark_online! if resource.respond_to?(:mark_online!)
          
          Rails.logger.info "User login successful: #{resource.email}"
          
          # devise-jwt will automatically add token to response headers
          render json: {
            status: 'success',
            message: 'Logged in successfully',
            user: serialize_user(resource)
          }, status: :ok
        end
        
      rescue => e
        Rails.logger.warn "Login failed: #{e.message}"
        render json: {
          status: 'error',
          message: 'Invalid email or password',
          code: 'invalid_credentials'
        }, status: :unauthorized
      end

      # ===========================================
      # 🚪 LOGOUT (Let devise-jwt handle token revocation)
      # ===========================================
      
      def destroy
        if current_user
          current_user.mark_offline! if current_user.respond_to?(:mark_offline!)
          Rails.logger.info "User logout: #{current_user.email}"
        end
        
        # Let devise-jwt handle token revocation through its normal flow
        sign_out(resource_name)
        
        render json: {
          status: 'success',
          message: 'Logged out successfully'
        }, status: :ok
      end

      # ===========================================
      # 🔐 GOOGLE LOGIN (FIXED - Using devise-jwt properly)
      # ===========================================

      def google_login
        credential = params[:credential]

        if credential.blank?
          return render json: { 
            status: 'error',
            message: 'Google token missing',
            code: 'missing_token'
          }, status: :unprocessable_entity
        end

        validator = GoogleIDToken::Validator.new
        
        begin
          payload = validator.check(credential, ENV['GOOGLE_CLIENT_ID'])
          email = payload['email']
          name = payload['name']
          google_avatar_url = payload['picture']
          first_name, last_name = name.split(' ', 2)

          user = User.find_or_initialize_by(email: email)
          is_new_user = user.new_record?
          
          if is_new_user
            user.first_name = first_name || 'Google'
            user.last_name = last_name || 'User'
            user.phone_number = nil
            user.password = Devise.friendly_token[0, 20]
            user.provider = 'google_oauth2'
            user.uid = payload['sub']
            user.google_image_url = google_avatar_url
            user.save!
            user.add_role(:client) if user.roles.blank?
            
            Rails.logger.info "New Google user created: #{email}"
          else
            Rails.logger.info "Existing Google user login: #{email}"
          end

          # Handle Google avatar attachment
          if google_avatar_url.present? && !user.avatar.attached?
            attach_google_avatar(user, google_avatar_url)
          end

          # Use devise-jwt's normal sign_in flow to generate token
          sign_in(user)
          user.mark_online! if user.respond_to?(:mark_online!)

          # devise-jwt will automatically add token to response headers
          render json: {
            status: 'success',
            message: 'Signed in with Google.',
            user: serialize_user(user),
            is_new_user: is_new_user
          }, status: :ok

        rescue GoogleIDToken::ValidationError => e
          Rails.logger.error "Google token invalid: #{e.message}"
          render json: { 
            status: 'error',
            message: 'Invalid Google token',
            code: 'invalid_token'
          }, status: :unauthorized
          
        rescue => e
          Rails.logger.error "Google login error: #{e.message}"
          render json: {
            status: 'error', 
            message: 'Google authentication failed',
            code: 'google_auth_failed'
          }, status: :internal_server_error
        end
      end

      # ===========================================
      # 🔍 SESSION INFO (Current user endpoint)
      # ===========================================
      
      def show
        if current_user
          render json: {
            status: 'success',
            user: serialize_user(current_user),
            authentication_method: 'devise-jwt'
          }, status: :ok
        else
          render json: {
            status: 'error',
            message: 'No active session',
            code: 'no_session'
          }, status: :unauthorized
        end
      end

      private

      # ===========================================
      # 🔧 USER SERIALIZATION
      # ===========================================

      def serialize_user(user)
        if defined?(UserSerializer)
          UserSerializer.new(user).as_json
        else
          # Fallback serialization
          user.as_json(
            only: [:id, :email, :first_name, :last_name, :phone_number, :created_at],
            methods: [:full_name, :display_name, :primary_role]
          ).merge(
            'google_user' => user.google_user?,
            'needs_password' => user.needs_password?,
            'roles' => user.roles.pluck(:name),
            'avatar_url' => avatar_url_for_user(user),
            'profile_complete' => user.profile_complete?
          )
        end
      end

      def avatar_url_for_user(user)
        if user.avatar.attached?
          begin
            Rails.application.routes.url_helpers.rails_blob_url(user.avatar, only_path: false)
          rescue => e
            Rails.logger.warn "Failed to generate avatar URL: #{e.message}"
            user.google_image_url
          end
        else
          user.google_image_url
        end
      end

      # ===========================================
      # 🖼️ GOOGLE AVATAR HANDLING
      # ===========================================

      def attach_google_avatar(user, avatar_url)
        return unless avatar_url.present?
        
        begin
          Rails.logger.info "Downloading Google avatar for #{user.email}"
          
          downloaded_image = URI.open(avatar_url)
          filename = "google_avatar_#{user.id}_#{Time.current.to_i}.jpg"
          
          user.avatar.attach(
            io: downloaded_image,
            filename: filename,
            content_type: 'image/jpeg'
          )
          
          Rails.logger.info "Google avatar attached for user: #{user.email}"
          
        rescue => e
          Rails.logger.warn "Failed to attach Google avatar for #{user.email}: #{e.message}"
          # Don't fail the login process if avatar attachment fails
        end
      end

      # ===========================================
      # 🔧 DEVISE OVERRIDES FOR JWT
      # ===========================================

      # Override respond_with to work properly with devise-jwt
      def respond_with(resource, _opts = {})
        if resource.persisted?
          render json: {
            status: 'success',
            message: 'Logged in successfully',
            user: serialize_user(resource)
          }, status: :ok
        else
          render json: {
            status: 'error',
            message: 'Login failed',
            errors: resource.errors.full_messages,
            code: 'login_failed'
          }, status: :unprocessable_entity
        end
      end

      def respond_to_on_destroy
        render json: { 
          status: 'success',
          message: 'Logged out successfully' 
        }, status: :ok
      end

      # ===========================================
      # 🔧 AUTHENTICATION HELPERS
      # ===========================================

      def auth_options
        { scope: resource_name, recall: "#{controller_path}#failure" }
      end

      def failure
        render json: {
          status: 'error',
          message: 'Authentication failed',
          code: 'auth_failed'
        }, status: :unauthorized
      end

      # ===========================================
      # 🔧 PARAMETER CONFIGURATION
      # ===========================================

      def configure_sign_in_params
        devise_parameter_sanitizer.permit(:sign_in, keys: [:email, :password])
      end

      def sign_in_params
        params.require(:user).permit(:email, :password)
      end
    end
  end
end