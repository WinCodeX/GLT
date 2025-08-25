# app/controllers/api/v1/me_controller.rb - PROPER Active Storage + R2
module Api
  module V1
    class MeController < ApplicationController
      before_action :authenticate_user!

      def show
        render json: { 
          id: current_user.id, 
          email: current_user.email,
          avatar_url: avatar_url_for_api
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
          Rails.logger.info "🖼️ Starting Active Storage + R2 upload for user #{current_user.id}"
          Rails.logger.info "📄 File: #{avatar_file.original_filename}, Size: #{avatar_file.size} bytes"
          Rails.logger.info "🗄️ Storage: #{Rails.application.config.active_storage.service}"
          
          # Remove existing avatar
          current_user.avatar.purge if current_user.avatar.attached?
          
          # Let Active Storage handle the upload to R2 (this should work with our R2 setup)
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
          
          avatar_url = avatar_url_for_api
          
          Rails.logger.info "✅ Avatar uploaded via Active Storage to R2"
          Rails.logger.info "🔗 Avatar URL: #{avatar_url}"
          
          render json: {
            success: true,
            message: 'Avatar updated successfully',
            avatar_url: avatar_url,
            # Additional info for debugging
            blob_info: {
              key: current_user.avatar.blob.key,
              service_name: current_user.avatar.blob.service_name,
              filename: current_user.avatar.filename.to_s
            }
          }
          
        rescue => e
          Rails.logger.error "❌ Active Storage upload error: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.first(10).join("\n")
          
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

      def avatar_url_for_api
        return nil unless current_user.avatar.attached?
        
        begin
          if Rails.env.production?
            # Production: Generate R2 public URL
            generate_r2_public_url
          else
            # Development: Use Rails URL helpers
            url_for(current_user.avatar)
          end
        rescue => e
          Rails.logger.error "❌ Avatar URL generation failed: #{e.message}"
          nil
        end
      end

      def generate_r2_public_url
        # Get R2 public URL base
        public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 'https://pub-63612670c2d64075820ce8724feff8ea.r2.dev'
        
        # Get the blob key from Active Storage
        blob_key = current_user.avatar.blob.key
        url = "#{public_base.chomp('/')}/#{blob_key}"
        
        Rails.logger.debug "🔗 Generated R2 URL: #{url}"
        return url
      rescue => e
        Rails.logger.error "❌ R2 URL generation failed: #{e.message}"
        nil
      end
    end
  end
end