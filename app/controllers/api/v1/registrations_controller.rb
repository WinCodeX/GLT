# app/controllers/api/v1/registrations_controller.rb - API-only version

module Api
  module V1
    class RegistrationsController < Devise::RegistrationsController
      respond_to :json
      before_action :configure_sign_up_params, only: [:create]
      before_action :configure_account_update_params, only: [:update]

      # ===========================================
      # 🔐 USER REGISTRATION
      # ===========================================

      def create
        build_resource(sign_up_params)

        # Check if email already exists with Google OAuth
        existing_user = User.find_by(email: resource.email)
        if existing_user&.google_user?
          return render json: {
            status: 'error',
            message: 'This email is already registered with Google. Please sign in with Google instead.',
            code: 'email_exists_with_google',
            suggestions: ['sign_in_with_google']
          }, status: :conflict
        end

        resource.save
        yield resource if block_given?
        
        if resource.persisted?
          # Add default role
          resource.add_role(:client) if resource.roles.blank?
          
          # User created successfully
          if resource.active_for_authentication?
            # Auto-confirm for API (adjust as needed)
            resource.update!(confirmed_at: Time.current) unless resource.confirmed_at
            
            # Let devise-jwt handle sign in and token generation
            sign_up(resource_name, resource)
            
            render json: {
              status: 'success',
              message: 'Registration successful',
              user: serialize_user(resource)
            }, status: :created
          else
            # Account created but needs confirmation
            render json: {
              status: 'success',
              message: 'Account created. Please check your email for confirmation instructions.',
              user: serialize_user(resource),
              requires_confirmation: true
            }, status: :created
          end
        else
          # Registration failed
          render json: {
            status: 'error',
            message: 'Registration failed',
            errors: resource.errors.full_messages,
            code: 'registration_failed'
          }, status: :unprocessable_entity
        end
      end

      # ===========================================
      # 🔄 ACCOUNT UPDATE
      # ===========================================

      def update
        self.resource = resource_class.to_adapter.get!(send(:"current_#{resource_name}").to_key)
        prev_unconfirmed_email = resource.unconfirmed_email if resource.respond_to?(:unconfirmed_email)

        # Handle Google users who need to set a password
        if resource.google_user? && params[:user][:password].present?
          resource_updated = update_google_user_with_password
        else
          resource_updated = update_resource(resource, account_update_params)
        end

        yield resource if block_given?
        
        if resource_updated
          bypass_sign_in resource, scope: resource_name if sign_in_after_change_password?

          render json: {
            status: 'success',
            message: 'Account updated successfully',
            user: serialize_user(resource)
          }, status: :ok
        else
          clean_up_passwords resource
          set_minimum_password_length
          
          render json: {
            status: 'error',
            message: 'Account update failed',
            errors: resource.errors.full_messages,
            code: 'update_failed'
          }, status: :unprocessable_entity
        end
      end

      # ===========================================
      # 🔐 GOOGLE USER PROFILE COMPLETION
      # ===========================================

      def complete_google_profile
        unless current_user&.google_user?
          return render json: {
            status: 'error',
            message: 'This endpoint is only for Google OAuth users',
            code: 'not_google_user'
          }, status: :bad_request
        end

        if current_user.update(google_profile_params)
          render json: {
            status: 'success',
            message: 'Profile completed successfully',
            user: serialize_user(current_user)
          }, status: :ok
        else
          render json: {
            status: 'error',
            message: 'Profile completion failed',
            errors: current_user.errors.full_messages,
            code: 'profile_completion_failed'
          }, status: :unprocessable_entity
        end
      end

      def set_password_for_google_user
        unless current_user&.google_user?
          return render json: {
            status: 'error',
            message: 'This endpoint is only for Google OAuth users',
            code: 'not_google_user'
          }, status: :bad_request
        end

        unless current_user.needs_password?
          return render json: {
            status: 'error',
            message: 'User already has a password set',
            code: 'password_already_set'
          }, status: :bad_request
        end

        password = params[:password]
        password_confirmation = params[:password_confirmation]

        if password.blank? || password_confirmation.blank?
          return render json: {
            status: 'error',
            message: 'Password and password confirmation are required',
            code: 'password_required'
          }, status: :bad_request
        end

        if current_user.set_password(password, password_confirmation)
          render json: {
            status: 'success',
            message: 'Password set successfully',
            user: serialize_user(current_user)
          }, status: :ok
        else
          render json: {
            status: 'error',
            message: 'Failed to set password',
            errors: current_user.errors.full_messages,
            code: 'password_set_failed'
          }, status: :unprocessable_entity
        end
      end

      # ===========================================
      # 🔍 ACCOUNT INFORMATION & VALIDATION
      # ===========================================

      def show
        if current_user
          render json: {
            status: 'success',
            user: serialize_user(current_user, include_sensitive: true)
          }, status: :ok
        else
          render json: {
            status: 'error',
            message: 'User not authenticated',
            code: 'not_authenticated'
          }, status: :unauthorized
        end
      end

      def check_email_availability
        email = params[:email]
        
        if email.blank?
          return render json: {
            status: 'error',
            message: 'Email parameter is required',
            code: 'email_required'
          }, status: :bad_request
        end

        existing_user = User.find_by(email: email)
        
        if existing_user
          if existing_user.google_user?
            render json: {
              status: 'unavailable',
              message: 'Email is registered with Google OAuth',
              code: 'email_exists_with_google',
              auth_method: 'google_oauth2'
            }, status: :ok
          else
            render json: {
              status: 'unavailable',
              message: 'Email is already registered',
              code: 'email_exists',
              auth_method: 'email_password'
            }, status: :ok
          end
        else
          render json: {
            status: 'available',
            message: 'Email is available for registration'
          }, status: :ok
        end
      end

      # ===========================================
      # 🔐 ACCOUNT LINKING (Google OAuth Integration)
      # ===========================================

      def link_google_account
        google_token = params[:google_token]
        
        unless google_token.present?
          return render json: {
            status: 'error',
            message: 'Google token is required',
            code: 'google_token_required'
          }, status: :bad_request
        end

        # Validate Google token
        service = GoogleOauthService.new
        result = service.validate_id_token(google_token)
        
        unless result[:success]
          return render json: {
            status: 'error',
            message: 'Invalid Google token',
            code: 'invalid_google_token'
          }, status: :bad_request
        end

        google_user_info = result[:user_info]
        
        # Check if Google email matches current user's email
        unless current_user.email == google_user_info[:email]
          return render json: {
            status: 'error',
            message: 'Google account email does not match your account email',
            code: 'email_mismatch'
          }, status: :bad_request
        end

        # Link the Google account
        if current_user.update(
          provider: 'google_oauth2',
          uid: google_user_info[:google_id],
          google_image_url: google_user_info[:picture]
        )
          render json: {
            status: 'success',
            message: 'Google account linked successfully',
            user: serialize_user(current_user)
          }, status: :ok
        else
          render json: {
            status: 'error',
            message: 'Failed to link Google account',
            errors: current_user.errors.full_messages,
            code: 'linking_failed'
          }, status: :unprocessable_entity
        end
      end

      def unlink_google_account
        unless current_user.google_user?
          return render json: {
            status: 'error',
            message: 'No Google account linked',
            code: 'no_google_account'
          }, status: :bad_request
        end

        # Check if user has a password to fall back to
        if current_user.encrypted_password.blank?
          return render json: {
            status: 'error',
            message: 'Cannot unlink Google account without setting a password first',
            code: 'password_required_for_unlinking'
          }, status: :bad_request
        end

        if current_user.update(provider: nil, uid: nil, google_image_url: nil)
          render json: {
            status: 'success',
            message: 'Google account unlinked successfully',
            user: serialize_user(current_user)
          }, status: :ok
        else
          render json: {
            status: 'error',
            message: 'Failed to unlink Google account',
            errors: current_user.errors.full_messages,
            code: 'unlinking_failed'
          }, status: :unprocessable_entity
        end
      end

      private

      # ===========================================
      # 🔧 HELPER METHODS
      # ===========================================

      def update_google_user_with_password
        # For Google users, handle password setting differently
        if account_update_params[:password].present?
          resource.password = account_update_params[:password]
          resource.password_confirmation = account_update_params[:password_confirmation]
        end
        
        # Update other attributes
        other_params = account_update_params.except(:password, :password_confirmation, :current_password)
        resource.assign_attributes(other_params)
        
        resource.save
      end

      def configure_sign_up_params
        devise_parameter_sanitizer.permit(:sign_up, keys: [
          :first_name, :last_name, :phone_number
        ])
      end

      def configure_account_update_params
        devise_parameter_sanitizer.permit(:account_update, keys: [
          :first_name, :last_name, :phone_number
        ])
      end

      def google_profile_params
        params.require(:user).permit(:first_name, :last_name, :phone_number)
      end

      def sign_up_params
        params.require(:user).permit(:email, :password, :password_confirmation, :first_name, :last_name, :phone_number)
      end

      def account_update_params
        params.require(:user).permit(:first_name, :last_name, :phone_number, :password, :password_confirmation, :current_password)
      end

      # Serialize user for JSON response
      def serialize_user(user, include_sensitive: false)
        if defined?(UserSerializer)
          serializer = UserSerializer.new(
            user,
            include_sensitive_info: include_sensitive
          )
          serializer.as_json
        else
          # Fallback manual serialization
          result = user.as_json(
            only: [:id, :email, :first_name, :last_name, :phone_number, :created_at],
            methods: [:full_name, :display_name, :primary_role]
          )
          
          # Add registration-specific information
          result.merge!(
            'google_user' => user.google_user?,
            'needs_password' => user.needs_password?,
            'profile_complete' => profile_complete?(user),
            'email_confirmed' => user.confirmed_at.present?,
            'roles' => user.roles.pluck(:name)
          )
          
          # Include sensitive info if requested
          if include_sensitive
            result.merge!(
              'provider' => user.provider,
              'has_password' => user.encrypted_password.present?,
              'avatar_url' => user.avatar.attached? ? 'avatar_attached' : user.google_image_url
            )
          end
          
          result
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
            message: 'Registration successful',
            user: serialize_user(resource)
          }, status: :created
        else
          render json: {
            status: 'error',
            message: 'Registration failed',
            errors: resource.errors.full_messages,
            code: 'registration_failed'
          }, status: :unprocessable_entity
        end
      end

      def respond_to_on_destroy
        render json: {
          status: 'success',
          message: 'Account deleted successfully'
        }, status: :ok
      end
    end
  end
end