# app/controllers/api/v1/avatars_controller.rb
module Api
  module V1
    class AvatarsController < ApplicationController
      # Skip authentication for public avatar access
      skip_before_action :authenticate_user!, only: [:show]
      
      def show
        user = User.find_by(id: params[:user_id])
        
        if !user || !user.avatar.attached?
          return send_default_avatar
        end
        
        begin
          blob = user.avatar.blob
          
          # Set proper caching headers
          expires_in 1.hour, public: true
          
          # Since we now use cloudflare storage, we should redirect to the public URL
          if Rails.env.production?
            redirect_to_r2_url(user)
          else
            # Development: serve directly
            send_data blob.download,
              type: blob.content_type || 'image/jpeg',
              disposition: 'inline',
              filename: blob.filename.to_s
          end
            
        rescue => e
          Rails.logger.error "❌ Error serving avatar for user #{params[:user_id]}: #{e.message}"
          send_default_avatar
        end
      end
      
      private
      
      def redirect_to_r2_url(user)
        # Try to get the R2 public URL
        begin
          # Use rails_blob_url which should now work with cloudflare service
          avatar_url = rails_blob_url(user.avatar, host: 'https://glt-53x8.onrender.com')
          redirect_to avatar_url, allow_other_host: true
        rescue => e
          Rails.logger.error "Failed to generate R2 URL: #{e.message}"
          send_default_avatar
        end
      end
      
      def send_default_avatar
        # Send a default generated avatar with proper redirect permission
        user_id = params[:user_id] || 'user'
        
        redirect_to "https://ui-avatars.com/api/?name=#{user_id}&size=150&background=6366f1&color=ffffff", 
                   allow_other_host: true
      end
    end
  end
end