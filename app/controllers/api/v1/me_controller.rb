# app/controllers/api/v1/me_controller.rb - FIXED: Simple, working avatar upload
module Api
  module V1
    class MeController < ApplicationController
      before_action :authenticate_user!

      def show
        begin
          render json: UserSerializer.new(current_user).serializable_hash
        rescue => e
          Rails.logger.error "Error in show: #{e.message}"
          render json: { 
            id: current_user.id, 
            email: current_user.email,
            avatar_url: safe_avatar_url
          }
        end
      end

      def update_avatar
        unless params[:avatar].present?
          return render json: { 
            success: false,
            error: 'No avatar file provided' 
          }, status: :bad_request
        end

        avatar_file = params[:avatar]
        
        # Basic validations
        unless avatar_file.respond_to?(:content_type)
          return render json: {
            success: false,
            error: 'Invalid file format'
          }, status: :bad_request
        end

        unless ['image/jpeg', 'image/jpg', 'image/png', 'image/gif'].include?(avatar_file.content_type.downcase)
          return render json: {
            success: false,
            error: 'Invalid file type. Please upload a JPG, PNG, or GIF image.'
          }, status: :bad_request
        end

        if avatar_file.size > 5.megabytes
          return render json: {
            success: false,
            error: 'File too large. Please upload an image smaller than 5MB.'
          }, status: :bad_request
        end

        begin
          Rails.logger.info "🖼️ Starting avatar upload for user #{current_user.id}"
          
          # Remove existing avatar if present
          if current_user.avatar.attached?
            Rails.logger.info "🗑️ Removing existing avatar"
            current_user.avatar.purge
          end

          # Attach new avatar - this should persist automatically
          Rails.logger.info "📎 Attaching new avatar"
          current_user.avatar.attach(avatar_file)
          
          # Force a reload to ensure we have the latest data
          current_user.reload
          
          if current_user.avatar.attached?
            Rails.logger.info "✅ Avatar attached successfully"
            
            # Simple avatar URL generation with fallback
            avatar_url = safe_avatar_url
            Rails.logger.info "🔗 Avatar URL: #{avatar_url}"
            
            # Return simple success response
            render json: {
              success: true,
              message: 'Avatar updated successfully',
              avatar_url: avatar_url
            }, status: :ok
          else
            Rails.logger.error "❌ Avatar attachment failed"
            render json: { 
              success: false,
              error: 'Avatar failed to attach' 
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "❌ Avatar upload error: #{e.message}"
          Rails.logger.error e.backtrace[0..5].join("\n")
          
          render json: { 
            success: false,
            error: 'Avatar upload failed'
          }, status: :internal_server_error
        end
      end

      def destroy_avatar
        begin
          if current_user.avatar.attached?
            current_user.avatar.purge
            render json: {
              success: true,
              message: 'Avatar deleted successfully',
              avatar_url: nil
            }, status: :ok
          else
            render json: {
              success: false,
              error: 'No avatar to delete'
            }, status: :not_found
          end
        rescue => e
          Rails.logger.error "❌ Avatar deletion error: #{e.message}"
          render json: {
            success: false,
            error: 'Failed to delete avatar'
          }, status: :internal_server_error
        end
      end

      private

      def safe_avatar_url
        return nil unless current_user.avatar.attached?
        
        begin
          # Try different URL generation methods
          if Rails.env.production?
            # Production - use full URL
            url_for(current_user.avatar)
          else
            # Development - try local URL
            request_base = "#{request.protocol}#{request.host_with_port}"
            rails_blob_url(current_user.avatar, host: request_base)
          end
        rescue => e
          Rails.logger.warn "Could not generate avatar URL: #{e.message}"
          nil
        end
      end
    end
  end
end