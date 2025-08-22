# app/controllers/api/v1/sessions_controller.rb - API-only version

module Api
  module V1
    class SessionsController < Devise::SessionsController
      respond_to :json

      # ===========================================
      # 🔐 REGULAR LOGIN
      # ===========================================

      def create
        resource = User.find_for_database_authentication(email: params[:user][:email])
        
        if resource&.valid_password?(params[:user][:password])
          if resource.confirmed_at.present?
            # Check if account is locked
            if resource.access_locked?
              return render json: {
                status: 'error',
                message: 'Your account is temporarily locked due to multiple failed login attempts',
                code: 'account_locked'
              }, status: :locked
            end

            # Let devise-jwt handle the sign in and token generation
            sign_in(resource)
            resource.mark_online!
            resource.unlock_access! if resource.respond_to?(:unlock_access!)
            
            render json: {
              status: 'success',
              message: 'Logged in successfully',
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
          # Handle failed attempts for lockable accounts
          if resource&.respond_to?(:failed_attempts)
            resource.increment(:failed_attempts) if resource
          end
          
          render json: {
            status: 'error',
            message: 'Invalid email or password',
            code: 'invalid_credentials'
          }, status: :unauthorized
        end
      end

      def destroy
        if current_user
          current_user.mark_offline!
          # devise-jwt handles token revocation automatically
          sign_out(current_user)
        end
        
        render json: {
          status: 'success',
          message: 'Logged out successfully'
        }, status: :ok
      end

      # ===========================================
      # 🔐 GOOGLE OAUTH METHODS
      # ===========================================

      # Step 1: Initialize Google OAuth flow
      def google_oauth_init
        state = SecureRandom.urlsafe_base64(32)
        
        # Store state in cache instead of session for API
        Rails.cache.write("oauth_state_#{state}", true, expires_in: 10.minutes)
        
        redirect_url = build_google_oauth_url(state)
        
        render json: {
          status: 'success',
          message: 'Google OAuth URL generated',
          auth_url: redirect_url,
          state: state
        }, status: :ok
      end

      # Step 2: Handle Google OAuth callback
      def google_oauth_callback
        Rails.logger.info "🔐 Google OAuth callback initiated"
        
        if params[:error].present?
          handle_oauth_error(params[:error], params[:error_description])
          return
        end

        # Verify state parameter for CSRF protection
        unless verify_oauth_state(params[:state])
          render json: {
            status: 'error',
            message: 'Invalid OAuth state parameter - possible CSRF attack',
            code: 'invalid_state'
          }, status: :bad_request
          return
        end

        begin
          # Use GoogleOauthService for token exchange
          service = GoogleOauthService.new
          result = service.exchange_code_for_tokens(
            params[:code], 
            "#{request.base_url}/api/v1/auth/google_oauth2/callback"
          )
          
          if result[:success]
            # Create or update user from Google data
            user = User.from_omniauth(build_auth_hash_from_service(result))
            
            if user.persisted?
              # Handle Google avatar
              handle_google_avatar(user, result[:user_info][:picture])
              
              # Let devise-jwt handle sign in and token generation
              sign_in(user)
              user.mark_online!
              
              render json: {
                status: 'success',
                message: 'Successfully authenticated with Google',
                user: serialize_user(user),
                auth_method: 'google_oauth2'
              }, status: :ok
            else
              render json: {
                status: 'error',
                message: 'Failed to create user account',
                errors: user.errors.full_messages,
                code: 'user_creation_failed'
              }, status: :unprocessable_entity
            end
          else
            handle_oauth_service_error(result)
          end

        rescue => e
          Rails.logger.error "❌ Google OAuth callback error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          render json: {
            status: 'error',
            message: 'Google authentication failed',
            code: 'oauth_error',
            details: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # Step 3: Handle Google token validation (for mobile apps)
      def google_login
        Rails.logger.info "🔐 Google token login initiated"
        
        # Support multiple parameter names for flexibility
        token = params[:credential] || params[:token] || params[:id_token] || params[:access_token]
        
        unless token.present?
          return render json: {
            status: 'error',
            message: 'Google token is required',
            code: 'missing_token',
            hint: 'Send token in credential, token, id_token, or access_token parameter'
          }, status: :bad_request
        end

        begin
          # Use GoogleOauthService for token validation
          service = GoogleOauthService.new
          result = service.validate_id_token(token)
          
          # Fallback to access token validation if ID token fails
          if !result[:success]
            Rails.logger.info "🔄 ID token validation failed, trying access token"
            result = service.validate_access_token(token)
          end
          
          unless result[:success]
            Rails.logger.error "❌ Google token validation failed: #{result[:error]}"
            return render json: {
              status: 'error',
              message: 'Invalid Google token',
              code: 'invalid_token',
              details: result[:error]
            }, status: :unauthorized
          end

          # Extract user info from validation result
          user_info = result[:user_info]
          
          # Find or create user
          user = find_or_create_google_user(user_info)
          
          if user.persisted?
            # Handle Google avatar
            handle_google_avatar(user, user_info[:picture])
            
            # Let devise-jwt handle sign in and token generation
            sign_in(user)
            user.mark_online!
            
            # Reset failed attempts if user was locked
            user.unlock_access! if user.respond_to?(:unlock_access!) && user.access_locked?
            
            render json: {
              status: 'success',
              message: 'Successfully signed in with Google',
              user: serialize_user(user),
              auth_method: 'google_token',
              is_new_user: user.created_at > 5.minutes.ago
            }, status: :ok
          else
            render json: {
              status: 'error',
              message: 'Failed to create user account',
              errors: user.errors.full_messages,
              code: 'user_creation_failed'
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "❌ Google token validation error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          render json: {
            status: 'error',
            message: 'Google token validation failed',
            code: 'token_validation_error',
            details: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # ===========================================
      # 🚫 OAUTH FAILURE HANDLER
      # ===========================================

      def oauth_failure
        error = params[:message] || params[:error] || 'Unknown OAuth error'
        description = params[:error_description] || 'Authentication failed'
        
        Rails.logger.error "❌ OAuth failure: #{error} - #{description}"
        
        render json: {
          status: 'error',
          message: 'Google authentication failed',
          error: error,
          description: description,
          code: 'oauth_failure'
        }, status: :bad_request
      end

      private

      # ===========================================
      # 🔧 GOOGLE USER MANAGEMENT
      # ===========================================

      def find_or_create_google_user(user_info)
        email = user_info[:email]
        
        # First, try to find by email
        user = User.find_by(email: email)
        
        if user
          # Update existing user with Google info if not already set
          update_existing_user_with_google_info(user, user_info)
        else
          # Create new user
          create_new_google_user(user_info)
        end
      end

      def update_existing_user_with_google_info(user, user_info)
        # Only update if user doesn't already have Google OAuth info
        unless user.google_user?
          user.update!(
            provider: 'google_oauth2',
            uid: user_info[:google_id],
            google_image_url: user_info[:picture],
            confirmed_at: user.confirmed_at || Time.current
          )
          Rails.logger.info "✅ Updated existing user #{user.email} with Google OAuth info"
        end
        
        user
      end

      def create_new_google_user(user_info)
        # Extract name components
        name_parts = user_info[:name]&.split(' ', 2) || []
        first_name = user_info[:given_name] || name_parts[0] || 'Google'
        last_name = user_info[:family_name] || name_parts[1] || 'User'
        
        user = User.new(
          email: user_info[:email],
          first_name: first_name,
          last_name: last_name,
          provider: 'google_oauth2',
          uid: user_info[:google_id],
          google_image_url: user_info[:picture],
          password: Devise.friendly_token[0, 20],
          confirmed_at: Time.current  # Auto-confirm Google users
        )
        
        if user.save
          # Assign default role
          user.add_role(:client) if user.roles.blank?
          Rails.logger.info "✅ Created new Google user: #{user.email}"
        else
          Rails.logger.error "❌ Failed to create Google user: #{user.errors.full_messages}"
        end
        
        user
      end

      # ===========================================
      # 🎨 AVATAR HANDLING
      # ===========================================

      def handle_google_avatar(user, google_avatar_url)
        return unless google_avatar_url.present?
        return if user.avatar.attached? # Don't overwrite existing avatar
        
        attach_google_avatar(user, google_avatar_url)
      end

      def attach_google_avatar(user, google_avatar_url)
        begin
          Rails.logger.info "🎨 Attempting to attach Google avatar for user #{user.email}"
          
          # Download the image from Google with timeout
          require 'open-uri'
          image_data = URI.open(
            google_avatar_url, 
            read_timeout: 10,
            'User-Agent' => 'Package Delivery App/1.0'
          )
          
          # Extract filename from URL or use default
          filename = extract_filename_from_url(google_avatar_url) || "google_avatar_#{user.id}.jpg"
          
          # Determine content type
          content_type = image_data.content_type || determine_content_type_from_url(google_avatar_url)
          
          # Attach to user
          user.avatar.attach(
            io: image_data,
            filename: filename,
            content_type: content_type
          )
          
          Rails.logger.info "✅ Successfully attached Google avatar for user #{user.email}"
        rescue StandardError => e
          Rails.logger.error "❌ Failed to attach Google avatar for user #{user.email}: #{e.message}"
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

      def determine_content_type_from_url(url)
        extension = File.extname(URI.parse(url).path).downcase
        case extension
        when '.jpg', '.jpeg'
          'image/jpeg'
        when '.png'
          'image/png'
        when '.gif'
          'image/gif'
        when '.webp'
          'image/webp'
        else
          'image/jpeg' # Default fallback
        end
      rescue
        'image/jpeg'
      end

      # ===========================================
      # 🔧 OAUTH HELPER METHODS
      # ===========================================

      def build_google_oauth_url(state)
        service = GoogleOauthService.new
        redirect_uri = "#{request.base_url}/api/v1/auth/google_oauth2/callback"
        service.generate_auth_url(redirect_uri, state)
      end

      def verify_oauth_state(state)
        return false unless state.present?
        
        # Check if state exists in cache (API-friendly approach)
        cache_key = "oauth_state_#{state}"
        if Rails.cache.exist?(cache_key)
          Rails.cache.delete(cache_key)  # Use once and delete
          true
        else
          false
        end
      end

      def build_auth_hash_from_service(service_result)
        user_info = service_result[:user_info]
        tokens = service_result[:tokens] || {}
        
        OpenStruct.new(
          provider: 'google_oauth2',
          uid: user_info[:google_id],
          info: OpenStruct.new(
            email: user_info[:email],
            name: user_info[:name],
            first_name: user_info[:given_name],
            last_name: user_info[:family_name],
            image: user_info[:picture]
          ),
          credentials: OpenStruct.new(
            token: tokens['access_token'],
            refresh_token: tokens['refresh_token'],
            expires_at: tokens['expires_in'] ? Time.current + tokens['expires_in'].to_i.seconds : nil
          )
        )
      end

      def handle_oauth_service_error(result)
        Rails.logger.error "❌ OAuth service error: #{result[:error]}"
        
        render json: {
          status: 'error',
          message: result[:error] || 'OAuth service error',
          code: result[:code] || 'service_error'
        }, status: :bad_request
      end

      def handle_oauth_error(error, description)
        Rails.logger.error "❌ OAuth Error: #{error} - #{description}"
        
        render json: {
          status: 'error',
          message: 'Google authentication was cancelled or failed',
          error: error,
          description: description,
          code: 'oauth_cancelled'
        }, status: :bad_request
      end

      # ===========================================
      # 🔧 UTILITY METHODS
      # ===========================================

      def configure_sign_in_params
        devise_parameter_sanitizer.permit(:sign_in, keys: [:email, :password])
      end

      # User serialization - no manual token handling needed with devise-jwt
      def serialize_user(user)
        if defined?(UserSerializer)
          UserSerializer.new(user).as_json
        else
          # Fallback if no serializer defined
          user.as_json(
            only: [:id, :email, :first_name, :last_name, :phone_number, :created_at],
            methods: [:full_name, :display_name, :primary_role, :google_user?, :needs_password?]
          )
        end
      end

      def profile_complete?(user)
        user.first_name.present? && 
        user.last_name.present? && 
        user.phone_number.present?
      end

      # ===========================================
      # 🔧 DEVISE OVERRIDES
      # ===========================================

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
            errors: resource.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      def respond_to_on_destroy
        render json: {
          status: 'success',
          message: 'Logged out successfully'
        }, status: :ok
      end
    end
  end
end