# app/controllers/api/v1/me_controller.rb - UPGRADED: Local + R2 support
module Api
  module V1
    class MeController < ApplicationController
      include AvatarHelper  # Include our new avatar helper
      
      before_action :authenticate_user!

      def show
        render json: { 
          id: current_user.id, 
          email: current_user.email,
          avatar_url: avatar_url(current_user, variant: :medium) # Uses AvatarHelper
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

        begin
          Rails.logger.info "🖼️ Starting avatar upload (#{Rails.env})"
          Rails.logger.info "📁 Storage service: #{Rails.application.config.active_storage.service}"
          
          # Remove existing avatar
          current_user.avatar.purge if current_user.avatar.attached?
          
          # Simple attachment - Active Storage handles R2 vs local automatically
          current_user.avatar.attach(
            io: avatar_file.tempfile,
            filename: avatar_file.original_filename || 'avatar.jpg',
            content_type: avatar_file.content_type || 'image/jpeg'
          )
          
          # Verify attachment was successful
          unless current_user.avatar.attached?
            raise "Avatar attachment failed"
          end
          
          Rails.logger.info "✅ Avatar uploaded successfully"
          Rails.logger.info "🔗 Avatar URL: #{avatar_url(current_user, variant: :medium)}"
          
          render json: {
            success: true,
            message: 'Avatar updated successfully',
            avatar_url: avatar_url(current_user, variant: :medium),
            # Return multiple sizes for your Expo app
            avatar_urls: {
              thumb: avatar_url(current_user, variant: :thumb),
              medium: avatar_url(current_user, variant: :medium),
              large: avatar_url(current_user, variant: :large)
            }
          }
          
        rescue => e
          Rails.logger.error "❌ Avatar upload error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          render json: { 
            success: false,
            error: "Upload failed: #{e.message}"
          }, status: :unprocessable_entity
        end
      end

      def destroy_avatar
        begin
          current_user.avatar.purge if current_user.avatar.attached?
          Rails.logger.info "🗑️ Avatar deleted for user #{current_user.id}"
          
          render json: { 
            success: true, 
            message: 'Avatar deleted',
            avatar_url: fallback_avatar_url(:medium) # Fallback from AvatarHelper
          }
        rescue => e
          Rails.logger.error "❌ Avatar deletion error: #{e.message}"
          render json: { 
            success: false, 
            error: 'Deletion failed' 
          }, status: :unprocessable_entity
        end
      end

      # Debug endpoint to test storage configuration
      def storage_debug
        return head :forbidden unless Rails.env.development?
        
        storage_info = {
          environment: Rails.env,
          active_storage_service: Rails.application.config.active_storage.service,
          host_info: host_debug_info, # From UrlHostHelper
          r2_config: {
            bucket: ENV['CLOUDFLARE_R2_BUCKET'],
            account_id: ENV['CLOUDFLARE_R2_ACCOUNT_ID'],
            public_url: ENV['CLOUDFLARE_R2_PUBLIC_URL'],
            has_credentials: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'].present?
          },
          user_avatar: {
            attached: current_user.avatar.attached?,
            url: current_user.avatar.attached? ? avatar_url(current_user) : nil
          }
        }
        
        render json: storage_info
      end

      private

      # Optional: Keep your simple method as backup
      def avatar_url_simple_backup
        return nil unless current_user.avatar.attached?
        
        begin
          if Rails.env.production?
            # In production, this should use R2 URLs
            avatar_url(current_user, variant: :medium)
          else
            # Development: use the original simple approach
            base_url = "#{request.protocol}#{request.host_with_port}"
            "#{base_url}/rails/active_storage/blobs/#{current_user.avatar.signed_id}/#{current_user.avatar.filename}"
          end
        rescue
          nil
        end
      end
    end
  end
end