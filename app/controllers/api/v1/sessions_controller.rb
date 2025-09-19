# app/controllers/api/v1/sessions_controller.rb - FIXED: No authentication interference
require 'google-id-token'
require 'open-uri'

module Api
  module V1
    class SessionsController < Devise::SessionsController
      respond_to :json
      
      # ===========================================
      # 🔐 REGULAR LOGIN (FIXED - Clean devise-jwt flow)
      # ===========================================

      def create
  self.resource = warden.authenticate!(auth_options)

  if resource
    sign_in(resource_name, resource)
    resource.mark_online! if resource.respond_to?(:mark_online!)

    Rails.logger.info "User login successful: #{resource.email}"

    # Extract the JWT token
    token = request.env['warden-jwt_auth.token']

    render json: {
      status: 'success',
      message: 'Logged in successfully',
      user: serialize_user(resource),
      token: token # 👈 Add the token here
    }, status: :ok
  else
    render json: {
      status: 'error',
      message: 'Authentication failed',
      code: 'auth_failed'
    }, status: :unauthorized
  end
end

      # ===========================================
      # 🚪 LOGOUT (Clean devise-jwt revocation)
      # ===========================================
      
      def destroy
        if current_user
          current_user.mark_offline! if current_user.respond_to?(:mark_offline!)
          Rails.logger.info "User logout: #{current_user.email}"
        end
        
        # Let devise-jwt handle token revocation cleanly
        sign_out(resource_name)
        
        render json: {
          status: 'success',
          message: 'Logged out successfully'
        }, status: :ok
      end

      # ===========================================
      # 🔐 GOOGLE LOGIN (FIXED - Clean authentication flow)
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

        begin
          # Validate Google token
          validator = GoogleIDToken::Validator.new
          payload = validator.check(credential, ENV['GOOGLE_CLIENT_ID'])
          
          # Extract user information
          email = payload['email']
          name = payload['name']
          google_avatar_url = payload['picture']
          first_name, last_name = name.split(' ', 2)

          # Find or create user
          user = User.find_or_initialize_by(email: email)
          is_new_user = user.new_record?
          
          if is_new_user
            user.assign_attributes(
              first_name: first_name || 'Google',
              last_name: last_name || 'User',
              phone_number: nil,
              password: Devise.friendly_token[0, 20],
              provider: 'google_oauth2',
              uid: payload['sub'],
              google_image_url: google_avatar_url
            )
            
            user.save!
            user.add_role(:client) if user.roles.blank?
            
            Rails.logger.info "New Google user created: #{email}"
          else
            Rails.logger.info "Existing Google user login: #{email}"
          end

          # Handle Google avatar attachment (non-blocking)
          if google_avatar_url.present? && !user.avatar.attached?
            attach_google_avatar(user, google_avatar_url)
          end

          # Clean sign_in flow for devise-jwt
          sign_in(:user, user)
          user.mark_online! if user.respond_to?(:mark_online!)

          # devise-jwt automatically adds token to response headers
          render json: {
            status: 'success',
            message: 'Signed in with Google.',
            user: serialize_user(user),
            is_new_user: is_new_user
          }, status: :ok

        rescue GoogleIDToken::ValidationError => e
          Rails.logger.error "Google token validation failed: #{e.message}"
          render json: { 
            status: 'error',
            message: 'Invalid Google token',
            code: 'invalid_google_token'
          }, status: :unauthorized
          
        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.error "User save failed: #{e.message}"
          render json: {
            status: 'error', 
            message: 'Failed to create user account',
            errors: e.record.errors.full_messages,
            code: 'user_creation_failed'
          }, status: :unprocessable_entity
          
        rescue => e
          Rails.logger.error "Google login unexpected error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
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
      # 🔧 DEVISE OVERRIDES FOR JWT (FIXED)
      # ===========================================

      # Clean respond_with for devise-jwt compatibility
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