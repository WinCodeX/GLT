require 'google-id-token'

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
          user: {
            id: resource.id,
            email: resource.email,
            first_name: resource.first_name,
            last_name: resource.last_name,
            phone_number: resource.phone_number,
            roles: resource.roles.pluck(:name)
          }
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
          first_name, last_name = name.split(' ', 2)

          user = User.find_or_initialize_by(email: email)
          if user.new_record?
            user.first_name = first_name || 'Google'
            user.last_name = last_name || 'User'
            user.phone_number = nil # Optional – update this if you extract phone from payload
            user.password = Devise.friendly_token[0, 20]
            user.skip_confirmation! if user.respond_to?(:skip_confirmation)
            user.save!
            user.add_role(:client) if user.roles.blank?
          end

          sign_in(user)
          jwt = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil).first

          render json: {
            message: 'Signed in with Google.',
            token: jwt,
            user: {
              id: user.id,
              email: user.email,
              first_name: user.first_name,
              last_name: user.last_name,
              phone_number: user.phone_number,
              roles: user.roles.pluck(:name)
            }
          }, status: :ok

        rescue GoogleIDToken::ValidationError => e
          Rails.logger.error "❌ Google token invalid: #{e.message}"
          render json: { error: 'Invalid Google token' }, status: :unauthorized
        end
      end
    end
  end
end