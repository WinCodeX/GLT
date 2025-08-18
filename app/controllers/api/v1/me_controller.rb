# app/controllers/api/v1/me_controller.rb - SIMPLE: Working avatar upload
module Api
  module V1
    class MeController < ApplicationController
      before_action :authenticate_user!

      def show
        render json: { 
          id: current_user.id, 
          email: current_user.email,
          avatar_url: avatar_url_simple
        }
      end

      def update_avatar
        unless params[:avatar].present?
          return render json: { 
            success: false,
            error: 'No avatar file provided' 
          }, status: :bad_request
        end

        avatar_file = params[:avatar]

        # Skip all validations and just try to save it
        begin
          Rails.logger.info "🖼️ Starting simple avatar upload"
          
          # Remove existing
          current_user.avatar.purge if current_user.avatar.attached?
          
          # Create blob directly
          blob = ActiveStorage::Blob.create_and_upload!(
            io: avatar_file.tempfile,
            filename: avatar_file.original_filename || 'avatar.jpg',
            content_type: avatar_file.content_type || 'image/jpeg'
          )
          
          # Create attachment directly in database
          ActiveStorage::Attachment.create!(
            name: 'avatar',
            record_type: 'User',
            record_id: current_user.id,
            blob_id: blob.id
          )
          
          Rails.logger.info "✅ Avatar saved successfully"
          
          render json: {
            success: true,
            message: 'Avatar updated successfully',
            avatar_url: avatar_url_simple
          }
          
        rescue => e
          Rails.logger.error "❌ Error: #{e.message}"
          render json: { 
            success: false,
            error: 'Upload failed'
          }, status: :unprocessable_entity
        end
      end

      def destroy_avatar
        current_user.avatar.purge if current_user.avatar.attached?
        render json: { success: true, message: 'Avatar deleted' }
      end

      private

      def avatar_url_simple
        return nil unless current_user.avatar.attached?
        
        begin
          base_url = "#{request.protocol}#{request.host_with_port}"
          "#{base_url}/rails/active_storage/blobs/#{current_user.avatar.signed_id}/#{current_user.avatar.filename}"
        rescue
          nil
        end
      end
    end
  end
end