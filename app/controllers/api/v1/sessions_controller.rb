require 'google-id-token'
require 'open-uri'

module Api
  module V1
    class SessionsController < Devise::SessionsController
      respond_to :json

      # POST /api/v1/login (Devise default)
      private def respond_with(resource, _opts = {})
        token = request.env['warden-jwt_auth.token']

        Rails.logger.info "✅ JWT token dispatched: #{token&.slice(0, 30)}..."
        Rails.logger.info "🔍 Request Path: #{request.path}"
        Rails.logger.info "🧪 User: #{resource.email}"

        render json: {
          message: "Logged in.",
          token: token,
          user: serialize_user(resource)
        }, status: :ok
      end

      def respond_to_on_destroy
        render json: { message: "Logged out." }, status: :ok
      end

      # POST /api/v1/google_login
      def google_login
        token = params[:credential]

        if token.blank?
          return render json: { error: 'Google token missing' }, status: :unprocessable_entity
        end

        validator = GoogleIDToken::Validator.new
        begin
          payload = validator.check(token, ENV['GOOGLE_CLIENT_ID'])
          email = payload['email']
          name  = payload['name']
          google_avatar_url = payload['picture'] # Google provides avatar URL in 'picture' field
          first_name, last_name = name.split(' ', 2)

          user = User.find_or_initialize_by(email: email)
          
          if user.new_record?
            user.first_name = first_name || 'Google'
            user.last_name = last_name || 'User'
            user.phone_number = nil
            user.password = Devise.friendly_token[0, 20]
            user.skip_confirmation! if user.respond_to?(:skip_confirmation)
            user.save!
            user.add_role(:client) if user.roles.blank?
          end

          # Handle Google avatar attachment
          if google_avatar_url.present? && !user.avatar.attached?
            attach_google_avatar(user, google_avatar_url)
          end

          sign_in(user)
          jwt = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil).first

          render json: {
            message: 'Signed in with Google.',
            token: jwt,
            user: serialize_user(user)
          }, status: :ok

        rescue GoogleIDToken::ValidationError => e
          Rails.logger.error "❌ Google token invalid: #{e.message}"
          render json: { error: 'Invalid Google token' }, status: :unauthorized
        end
      end

      private

      # Serialize user data using your existing UserSerializer
      def serialize_user(user)
        UserSerializer.new(user).as_json
      end

      # Download and attach Google avatar to user
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

      # Extract filename from Google avatar URL
      def extract_filename_from_url(url)
        uri = URI.parse(url)
        File.basename(uri.path).presence || nil
      rescue
        nil
      end
    end
  end
end