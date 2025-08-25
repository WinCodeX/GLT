# app/controllers/api/v1/me_controller.rb - ORIGINAL + R2 URL GENERATION
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

        begin
          Rails.logger.info "🖼️ Starting avatar upload for user #{current_user.id}"
          Rails.logger.info "📄 File: #{avatar_file.original_filename}, Size: #{avatar_file.size} bytes"
          Rails.logger.info "🗄️ Storage: #{Rails.application.config.active_storage.service}"
          
          # Remove existing avatar
          current_user.avatar.purge if current_user.avatar.attached?
          
          # Use simple attach method (let the initializer handle R2 compatibility)
          current_user.avatar.attach(avatar_file)
          
          # Verify attachment
          current_user.reload
          unless current_user.avatar.attached?
            raise "Avatar attachment failed"
          end
          
          avatar_url = avatar_url_simple
          Rails.logger.info "✅ Avatar uploaded successfully"
          Rails.logger.info "🔗 Avatar URL: #{avatar_url}"
          
          render json: {
            success: true,
            message: 'Avatar updated successfully',
            avatar_url: avatar_url
          }
          
        rescue => e
          Rails.logger.error "❌ Avatar upload error: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          
          render json: { 
            success: false,
            error: "Upload failed: #{e.message}"
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
          if Rails.env.production?
            # Production: Use R2 public URL
            public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL']
            
            if public_base.blank?
              Rails.logger.error "❌ CLOUDFLARE_R2_PUBLIC_URL not configured!"
              return fallback_to_rails_url
            end
            
            blob_key = current_user.avatar.blob.key
            url = "#{public_base.chomp('/')}/#{blob_key}"
            Rails.logger.info "🔗 Generated R2 URL: #{url}"
            return url
            
          else
            # Development: Use Rails URLs
            base_url = "#{request.protocol}#{request.host_with_port}"
            "#{base_url}/rails/active_storage/blobs/#{current_user.avatar.signed_id}/#{current_user.avatar.filename}"
          end
        rescue => e
          Rails.logger.error "❌ Avatar URL generation failed: #{e.message}"
          fallback_to_rails_url
        end
      end
      
      def fallback_to_rails_url
        begin
          base_url = "https://glt-53x8.onrender.com"
          "#{base_url}/rails/active_storage/blobs/#{current_user.avatar.signed_id}/#{current_user.avatar.filename}"
        rescue
          nil
        end
      end
    end
  end
end