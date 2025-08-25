# app/controllers/api/v1/avatars_controller.rb - Fixed to bypass authentication
module Api
  module V1
    class AvatarsController < ApplicationController
      # Skip authentication for public avatar access
      skip_before_action :authenticate_user!, only: [:show]
      # If you have other auth callbacks, skip them too:
      # skip_before_action :verify_authenticity_token, only: [:show]
      
      def show
        user = User.find_by(id: params[:user_id])
        
        if !user || !user.avatar.attached?
          return send_default_avatar
        end
        
        begin
          blob = user.avatar.blob
          
          # Set proper caching headers
          expires_in 1.hour, public: true
          
          # Get image data from R2
          image_data = if Rails.env.production?
            get_image_from_r2(blob.key)
          else
            blob.download  # Local storage in development
          end
          
          # Send image with proper headers
          send_data image_data,
            type: blob.content_type || 'image/jpeg',
            disposition: 'inline',
            filename: blob.filename.to_s
            
        rescue => e
          Rails.logger.error "❌ Error serving avatar for user #{params[:user_id]}: #{e.message}"
          send_default_avatar
        end
      end
      
      private
      
      def get_image_from_r2(blob_key)
        require 'aws-sdk-s3'
        
        # Create R2 client
        client = Aws::S3::Client.new(
          access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
          secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
          region: 'auto',
          endpoint: "https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com",
          force_path_style: true
        )
        
        # Get the file from R2
        response = client.get_object(
          bucket: ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp',
          key: blob_key
        )
        
        response.body.read
      end
      
      def send_default_avatar
        # Send a default generated avatar or 404
        user_id = params[:user_id] || 'user'
        
        # Option 1: Redirect to default avatar service
        redirect_to "https://ui-avatars.com/api/?name=#{user_id}&size=150&background=6366f1&color=ffffff"
        
        # Option 2: Return 404 (uncomment this and comment above if preferred)
        # head :not_found
      end
    end
  end
end