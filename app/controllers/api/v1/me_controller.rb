# app/controllers/api/v1/me_controller.rb - DIRECT R2 UPLOAD
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
          Rails.logger.info "🖼️ Starting DIRECT R2 avatar upload for user #{current_user.id}"
          Rails.logger.info "📄 File: #{avatar_file.original_filename}, Size: #{avatar_file.size} bytes"
          
          # Remove existing avatar first
          current_user.avatar.purge if current_user.avatar.attached?
          
          # Upload directly to R2 without Active Storage's upload process
          uploaded_key = upload_directly_to_r2(avatar_file)
          
          # Create the Active Storage records manually
          blob = ActiveStorage::Blob.create!(
            key: uploaded_key,
            filename: avatar_file.original_filename || 'avatar.jpg',
            content_type: avatar_file.content_type || 'image/jpeg',
            byte_size: avatar_file.size,
            checksum: nil, # Don't store checksum to avoid conflicts
            service_name: 'cloudflare'
          )
          
          # Create the attachment
          ActiveStorage::Attachment.create!(
            name: 'avatar',
            record_type: 'User',
            record_id: current_user.id,
            blob_id: blob.id
          )
          
          current_user.reload
          avatar_url = avatar_url_simple
          
          Rails.logger.info "✅ Avatar uploaded directly to R2 successfully"
          Rails.logger.info "🔗 Avatar URL: #{avatar_url}"
          
          render json: {
            success: true,
            message: 'Avatar updated successfully',
            avatar_url: avatar_url
          }
          
        rescue => e
          Rails.logger.error "❌ Direct R2 upload error: #{e.class} - #{e.message}"
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

      def upload_directly_to_r2(file)
        # Generate a unique key for the file
        key = "avatars/#{SecureRandom.uuid}/#{file.original_filename}"
        
        # Get R2 client directly - ensure AWS SDK is loaded
        require 'aws-sdk-s3'
        
        client = Aws::S3::Client.new(
          access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
          secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
          region: 'auto',
          endpoint: "https://#{ENV['CLOUDFLARE_R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
          force_path_style: true
        )
        
        # Upload with minimal options to avoid checksum conflicts
        client.put_object(
          bucket: ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp',
          key: key,
          body: file.tempfile,
          content_type: file.content_type
          # No checksum parameters at all
        )
        
        Rails.logger.info "📤 File uploaded directly to R2 with key: #{key}"
        return key
      end

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