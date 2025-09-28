module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      begin
        # Extract token and user_id from params
        token = request.params[:token]
        user_id = request.params[:user_id]

        Rails.logger.info "ActionCable connection attempt - Token: #{token&.first(10)}..., User ID: #{user_id}"

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
          decoded_token = JWT.decode(token, Rails.application.credentials.devise_jwt_secret_key || ENV['DEVISE_JWT_SECRET_KEY'])
          jwt_user_id = decoded_token[0]['sub']

          # Ensure token user matches requested user
          if jwt_user_id.to_s != user_id.to_s
            Rails.logger.error "ActionCable connection rejected - Token user mismatch: #{jwt_user_id} vs #{user_id}"
            reject_unauthorized_connection
          end

          Rails.logger.info "ActionCable connection established for user: #{user.id} (#{user.email})"
          user
        rescue JWT::DecodeError => e
          Rails.logger.error "ActionCable connection rejected - Invalid JWT: #{e.message}"
          reject_unauthorized_connection
        end
      rescue => e
        Rails.logger.error "ActionCable connection error: #{e.message}"
        reject_unauthorized_connection
      end
    end
  end
end