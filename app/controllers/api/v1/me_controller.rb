module Api
  module V1
    class MeController < ApplicationController
      before_action :authenticate_user!

      include Rails.application.routes.url_helpers
      include UrlHostHelper  # Add this to match UserSerializer

      def show
        render json: UserSerializer.new(current_user).serializable_hash
      end

      def update_avatar
        unless params[:avatar].present?
          return render json: { 
            error: 'No avatar file provided' 
          }, status: :bad_request
        end

        begin
          current_user.avatar.attach(params[:avatar])

          if current_user.avatar.attached?
            # Generate avatar URL consistent with UserSerializer
            avatar_url = generate_avatar_url(current_user)
            
            render json: {
              message: 'Avatar updated successfully',
              avatar_url: avatar_url,
              user: UserSerializer.new(current_user).serializable_hash[:data][:attributes]
            }, status: :ok
          else
            render json: { 
              error: 'Avatar failed to upload' 
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "Avatar upload error: #{e.message}"
          render json: { 
            error: 'Avatar upload failed',
            details: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # Add method to delete avatar
      def destroy_avatar
        if current_user.avatar.attached?
          current_user.avatar.purge
          render json: {
            message: 'Avatar deleted successfully',
            avatar_url: nil
          }, status: :ok
        else
          render json: {
            error: 'No avatar to delete'
          }, status: :not_found
        end
      end

      private

      def generate_avatar_url(user)
        return nil unless user.avatar.attached?

        host = first_available_host
        return nil unless host

        begin
          rails_blob_url(user.avatar, host: host)
        rescue => e
          Rails.logger.error "Error generating avatar URL: #{e.message}"
          nil
        end
      end
    end
  end
end