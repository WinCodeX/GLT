# app/channels/application_cable/connection.rb
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      # Try web session authentication first (for admin web interface)
      if (user = find_user_from_session)
        Rails.logger.info "ActionCable connection established via web session for user: #{user.id} (#{user.email})"
        return user
      end
      
      # Fall back to JWT token authentication (for mobile apps)
      find_user_from_jwt
    end

    def find_user_from_session
      # Check if there's a valid web session (cookie-based)
      # This uses the same session that Devise uses for web authentication
      user_id = cookies.encrypted[Rails.application.config.session_options[:key]]&.dig('warden.user.user.key', 0, 0)
      
      if user_id
        user = User.find_by(id: user_id)
        return user if user
      end
      
      nil
    rescue => e
      Rails.logger.error "Web session authentication failed: #{e.message}"
      nil
    end

    def find_user_from_jwt
      # Extract token and user_id from params
      token = request.params[:token]
      user_id = request.params[:user_id]

      Rails.logger.info "ActionCable JWT connection attempt - Token: #{token&.first(10)}..., User ID: #{user_id}"

      # Reject if either is missing
      if token.blank? || user_id.blank?
        Rails.logger.error "ActionCable connection rejected - Missing token or user_id"
        reject_unauthorized_connection
      end

      # Find user by ID
      user = User.find_by(id: user_id)
      unless user
        Rails.logger.error "ActionCable connection rejected - User not found: #{user_id}"
        reject_unauthorized_connection
      end

      # Verify JWT token
      begin
        decoded_token = JWT.decode(
          token, 
          Rails.application.credentials.devise_jwt_secret_key || ENV['DEVISE_JWT_SECRET_KEY']
        )
        jwt_user_id = decoded_token[0]['sub']

        # Ensure token user matches requested user
        if jwt_user_id.to_s != user_id.to_s
          Rails.logger.error "ActionCable connection rejected - Token user mismatch: #{jwt_user_id} vs #{user_id}"
          reject_unauthorized_connection
        end

        Rails.logger.info "ActionCable connection established via JWT for user: #{user.id} (#{user.email})"
        user
      rescue JWT::DecodeError => e
        Rails.logger.error "ActionCable connection rejected - Invalid JWT: #{e.message}"
        reject_unauthorized_connection
      end
    rescue => e
      Rails.logger.error "ActionCable JWT authentication error: #{e.message}"
      reject_unauthorized_connection
    end
  end
end