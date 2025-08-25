# app/controllers/api/v1/me_controller.rb - Updated to use Rails URLs
module Api
  module V1
    class MeController < ApplicationController
      before_action :authenticate_user!

      def show
        render json: { 
          id: current_user.id, 
          email: current_user.email,
          avatar_url: rails_avatar_url
        }
      end

      def update_avatar
        # Keep your existing update_avatar method exactly as it is
        # The upload part stays the same, only URL generation changes
        
        unless params[:avatar].present?
          return render json: { 
            success: false,
            error: 'No avatar file provided' 
          }, status: :bad_request
        end

        avatar_file = params[:avatar]

        begin
          Rails.logger.info "🖼️ Starting avatar upload for user #{current_user.id}"
          
          # Remove existing avatar
          current_user.avatar.purge if current_user.avatar.attached?
          
          # Upload to R2 via Active Storage (same as before)
          current_user.avatar.attach(
            io: avatar_file.tempfile,
            filename: avatar_file.original_filename || 'avatar.jpg',
            content_type: avatar_file.content_type || 'image/jpeg'
          )
          
          # Verify attachment
          current_user.reload
          unless current_user.avatar.attached?
            raise "Avatar attachment failed"
          end
          
          Rails.logger.info "✅ Avatar uploaded successfully"
          Rails.logger.info "🔗 Avatar will be served at: #{rails_avatar_url}"
          
          render json: {
            success: true,
            message: 'Avatar updated successfully',
            avatar_url: rails_avatar_url  # Now returns Rails URL instead of R2
          }
          
        rescue => e
          Rails.logger.error "❌ Avatar upload error: #{e.message}"
          render json: { 
            success: false,
            error: "Upload failed: #{e.message}"
          }, status: :unprocessable_entity
        end
      end

      def destroy_avatar
        current_user.avatar.purge if current_user.avatar.attached?
        current_user.reload
        
        render json: { 
          success: true, 
          message: 'Avatar deleted',
          avatar_url: nil
        }
      end

      private

      def rails_avatar_url
        return nil unless current_user.avatar.attached?
        
        # Generate Rails URL that will serve the image
        base_url = Rails.env.production? ? 'https://glt-53x8.onrender.com' : 'http://192.168.100.73:3000'
        "#{base_url}/api/v1/users/#{current_user.id}/avatar"
      end
    end
  end
end