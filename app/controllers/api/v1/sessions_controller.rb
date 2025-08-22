# app/controllers/api/v1/sessions_controller.rb - Fixed version
require 'google-id-token'
require 'open-uri'

module Api
  module V1
    class SessionsController < Devise::SessionsController
      respond_to :json

      # ===========================================
      # 🔐 REGULAR LOGIN (Fixed)
      # ===========================================

      def create
        resource = User.find_for_database_authentication(email: params[:user][:email])
        
        if resource&.valid_password?(params[:user][:password])
          if resource.confirmed_at.present?
            # Sign in the user
            sign_in(resource)
            resource.mark_online! if resource.respond_to?(:mark_online!)
            
            # Get JWT token from warden (if JWT is enabled)
            token = request.env['warden-jwt_auth.token']
            
            render json: {
              status: 'success',
              message: 'Logged in successfully',
              token: token,
              user: serialize_user(resource)
            }, status: :ok
          else
            render json: {
              status: 'error',
              message: 'Please confirm your email address before signing in',
              code: 'email_not_confirmed'
            }, status: :unauthorized
          end
        else
          render json: {
            status: 'error',
            message: 'Invalid email or password',
            code: 'invalid_credentials'
          }, status: :unauthorized
        end
      end

      def destroy
        if current_user
          current_user.mark_offline! if current_user.respond_to?(:mark_offline!)
          sign_out(current_user)
        end
        
        render json: {
          status: 'success',
          message: 'Logged out successfully'
        }, status: :ok
      end

      # ===========================================
      # 🔐 GOOGLE LOGIN (From your working controller)
      # ===========================================

      def google_login
        token = params[:credential]

        if token.blank?
          return render json: { 
            status: 'error',
            message: 'Google token missing',
            code: 'missing_token'
          }, status: :unprocessable_entity
        end

        validator = GoogleIDToken::Validator.new
        begin
          payload = validator.check(token, ENV['GOOGLE_CLIENT_ID'])
          email = payload['email']
          name  = payload['name']
          google_avatar_url = payload['picture']
          first_name, last_name = name.split(' ', 2)

          user = User.find_or_initialize_by(email: email)
          
          if user.new_record?
            user.first_name = first_name || 'Google'
            user.last_name = last_name || 'User'
            user.phone_number = nil
            user.password = Devise.friendly_token[0, 20]
            user.skip_confirmation! if user.respond_to?(:skip_confirmation!)
            user.confirmed_at = Time.current
            user.provider = 'google_oauth2'
            user.uid = payload['sub'] # Google's user ID
            user.google_image_url = google_avatar_url
            user.save!
            user.add_role(:client) if user.roles.blank?
          end

          # Handle Google avatar attachment
          if google_avatar_url.present? && !user.avatar.attached?
            attach_google_avatar(user, google_avatar_url)
          end

          sign_in(user)
          user.mark_online! if user.respond_to?(:mark_online!)
          
          # Get JWT token from request or generate one
          jwt = request.env['warden-jwt_auth.token']
          
          # If no JWT from warden, try to generate one manually (fallback)
          unless jwt
            begin
              jwt = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil).first
            rescue => e
              Rails.logger.warn "Could not generate JWT: #{e.message}"
              jwt = nil
            end
          end

          render json: {
            status: 'success',
            message: 'Signed in with Google.',
            token: jwt,
            user: serialize_user(user)
          }, status: :ok

        rescue GoogleIDToken::ValidationError => e
          Rails.logger.error "❌ Google token invalid: #{e.message}"
          render json: { 
            status: 'error',
            message: 'Invalid Google token',
            code: 'invalid_token'
          }, status: :unauthorized
        rescue => e
          Rails.logger.error "❌ Google login error: #{e.message}"
          render json: {
            status: 'error', 
            message: 'Google authentication failed',
            code: 'google_auth_failed'
          }, status: :internal_server_error
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
            'avatar_url' => user.avatar.attached? ? 'avatar_attached' : user.google_image_url
          )
        end
      end

      # ===========================================
      # 🎨 GOOGLE AVATAR HANDLING
      # ===========================================

      def attach_google_avatar(user, google_avatar_url)
        begin
          # Download the image from Google
          image_data = URI.open(google_avatar_url)
          
          # Extract filename from URL or use default
          filename = extract_filename_from_url(google_avatar_url) || "google_avatar_#{user.id}.jpg"
          
          # Attach to user
          user.avatar.attach(
            io: image_data,
            filename: filename,
            content_type: image_data.content_type || 'image/jpeg'
          )
          
          Rails.logger.info "✅ Avatar attached for user #{user.email}"
        rescue StandardError => e
          Rails.logger.error "❌ Failed to attach Google avatar: #{e.message}"
          # Don't fail the login process if avatar attachment fails
        end
      end

      def extract_filename_from_url(url)
        uri = URI.parse(url)
        basename = File.basename(uri.path)
        return nil if basename.blank? || basename == '/' || basename == '.'
        
        # Ensure it has an extension
        basename.include?('.') ? basename : "#{basename}.jpg"
      rescue
        nil
      end

      # ===========================================
      # 🔧 DEVISE OVERRIDES (Simplified)
      # ===========================================

      # Override Devise's respond_with for regular login
      def respond_with(resource, _opts = {})
        if resource.persisted?
          token = request.env['warden-jwt_auth.token']
          
          Rails.logger.info "✅ JWT token dispatched: #{token&.slice(0, 30)}..." if token
          Rails.logger.info "🔍 Request Path: #{request.path}"
          Rails.logger.info "🧪 User: #{resource.email}"

          render json: {
            status: 'success',
            message: "Logged in successfully.",
            token: token,
            user: serialize_user(resource)
          }, status: :ok
        else
          render json: {
            status: 'error',
            message: 'Login failed',
            errors: resource.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      def respond_to_on_destroy
        render json: { 
          status: 'success',
          message: "Logged out successfully." 
        }, status: :ok
      end

      # ===========================================
      # 🔧 PARAMETER CONFIGURATION
      # ===========================================

      def configure_sign_in_params
        devise_parameter_sanitizer.permit(:sign_in, keys: [:email, :password])
      end
    end
  end
end