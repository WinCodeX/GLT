# app/controllers/api/v1/me_controller.rb - UPGRADED: Local + R2 support
module Api
  module V1
    class MeController < ApplicationController
      include AvatarHelper  # Include our avatar helper
      
      before_action :authenticate_user!

      def show
        render json: { 
          id: current_user.id, 
          email: current_user.email,
          avatar_url: avatar_url(current_user, variant: :medium), # Fixed: Use AvatarHelper
          # Add debug info in development
          debug: Rails.env.development? ? avatar_debug_info : nil
        }.compact # Remove debug key if nil
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
      def avatar_debug
        return head :forbidden unless Rails.env.development?
        
        debug_info = {
          environment: Rails.env,
          storage_service: Rails.application.config.active_storage.service,
          user_id: current_user.id,
          avatar_attached: current_user.avatar.attached?,
          avatar_info: current_user.avatar.attached? ? {
            filename: current_user.avatar.filename.to_s,
            content_type: current_user.avatar.content_type,
            byte_size: current_user.avatar.byte_size,
            blob_key: current_user.avatar.blob.key,
            service_name: current_user.avatar.blob.service_name
          } : nil,
          generated_url: current_user.avatar.attached? ? avatar_url(current_user, variant: :medium) : nil,
          host_info: host_debug_info, # From UrlHostHelper
          r2_config: {
            bucket: ENV['CLOUDFLARE_R2_BUCKET'],
            account_id: ENV['CLOUDFLARE_R2_ACCOUNT_ID'],
            public_url: ENV['CLOUDFLARE_R2_PUBLIC_URL'],
            has_access_key: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'].present?,
            has_secret_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'].present?
          }
        }
        
        render json: debug_info
      end

      private

      # Debug info for avatar generation
      def avatar_debug_info
        return nil unless Rails.env.development?
        
        {
          attached: current_user.avatar.attached?,
          storage_service: Rails.application.config.active_storage.service,
          generated_url: current_user.avatar.attached? ? avatar_url(current_user, variant: :medium) : nil
        }
      end
    end
  end
end