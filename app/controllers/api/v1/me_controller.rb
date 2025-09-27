# app/controllers/api/v1/me_controller.rb - Fixed for R2 user folders
module Api
  module V1
    class MeController < ApplicationController
      include AvatarHelper
      
      before_action :authenticate_user!

      def show
        # Use the comprehensive UserSerializer but handle avatar separately
        serializer = UserSerializer.new(
          current_user,
          include_sensitive_info: true,
          context: 'profile'
        )
        
        # Get serialized user data and add avatar_url from controller
        user_data = serializer.as_json
        user_data[:avatar_url] = avatar_api_url(current_user)
        
        render json: {
          status: 'success',
          user: user_data
        }
      end

      def update
        user_params = params.require(:user).permit(
          :first_name, :last_name, :phone_number, :email
        )

        if current_user.update(user_params)
          serializer = UserSerializer.new(
            current_user,
            include_sensitive_info: true,
            context: 'profile'
          )
          
          user_data = serializer.as_json
          user_data[:avatar_url] = avatar_api_url(current_user)
          
          render json: {
            status: 'success',
            message: 'Profile updated successfully',
            user: user_data
          }
        else
          render json: {
            status: 'error',
            message: 'Profile update failed',
            errors: current_user.errors.full_messages
          }, status: :unprocessable_entity
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

        # Add file validation
        if avatar_file.size > 5.megabytes
          return render json: { 
            success: false,
            error: 'File too large (max 5MB)' 
          }, status: :bad_request
        end

        unless avatar_file.content_type&.start_with?('image/')
          return render json: { 
            success: false,
            error: 'Invalid file type. Please upload an image.' 
          }, status: :bad_request
        end

        begin
          Rails.logger.info "🖼️ Starting avatar upload for user #{current_user.id}"
          Rails.logger.info "📁 File: #{avatar_file.original_filename} (#{avatar_file.size} bytes)"
          Rails.logger.info "🔧 Content-Type: #{avatar_file.content_type}"
          
          if Rails.env.production?
            # Production: Upload directly to R2 with user ID folder structure
            new_avatar_url = upload_avatar_to_r2(current_user, avatar_file)
          else
            # Development: Use Active Storage as before
            current_user.avatar.purge if current_user.avatar.attached?
            current_user.avatar.attach(
              io: avatar_file.tempfile,
              filename: avatar_file.original_filename || 'avatar.jpg',
              content_type: avatar_file.content_type || 'image/jpeg'
            )
            current_user.reload
            new_avatar_url = avatar_api_url(current_user)
          end
          
          Rails.logger.info "✅ Avatar uploaded successfully"
          Rails.logger.info "🔗 Avatar URL: #{new_avatar_url}"
          
          # Return updated user data with new avatar
          serializer = UserSerializer.new(
            current_user,
            include_sensitive_info: true,
            context: 'profile'
          )
          
          user_data = serializer.as_json
          user_data[:avatar_url] = new_avatar_url
          
          render json: {
            success: true,
            message: 'Avatar updated successfully',
            avatar_url: new_avatar_url,
            user: user_data
          }
          
        rescue => e
          Rails.logger.error "❌ Avatar upload error: #{e.message}"
          Rails.logger.error "📍 Backtrace: #{e.backtrace.first(10).join('\n')}"
          
          # Check if it's a storage-specific error
          error_message = case e.message
          when /Access Denied/i, /403/
            "Storage access denied. Check R2 credentials and permissions."
          when /bucket.*not.*found/i, /404/
            "Storage bucket not found. Check R2 bucket configuration."
          when /timeout/i
            "Upload timeout. Please try again."
          when /network/i, /connection/i
            "Network error. Check internet connection."
          else
            "Upload failed: #{e.message}"
          end
          
          render json: { 
            success: false,
            error: error_message
          }, status: :unprocessable_entity
        end
      end

      def destroy_avatar
        if Rails.env.production?
          # Production: Delete from R2
          delete_avatar_from_r2(current_user)
        else
          # Development: Delete from Active Storage
          current_user.avatar.purge if current_user.avatar.attached?
          current_user.reload
        end
        
        # Return updated user data without avatar
        serializer = UserSerializer.new(
          current_user,
          include_sensitive_info: true,
          context: 'profile'
        )
        
        user_data = serializer.as_json
        user_data[:avatar_url] = avatar_api_url(current_user) # This will now return nil
        
        render json: { 
          success: true, 
          message: 'Avatar deleted',
          avatar_url: user_data[:avatar_url],
          user: user_data
        }
      end

      private

      def upload_avatar_to_r2(user, avatar_file)
        require 'aws-sdk-s3'
        
        # Create R2 client
        client = Aws::S3::Client.new(
          access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
          secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
          region: 'auto',
          endpoint: ENV['CLOUDFLARE_R2_ENDPOINT'] || 'https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com',
          force_path_style: true
        )

        bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
        
        # Define the R2 key with user folder structure: avatars/{user_id}/avatar.jpg
        file_extension = File.extname(avatar_file.original_filename || 'avatar.jpg')
        r2_key = "avatars/#{user.id}/avatar#{file_extension}"
        
        Rails.logger.info "📂 R2 Key: #{r2_key}"
        
        # Delete all existing avatars in user's folder (handles different file extensions)
        user_prefix = "avatars/#{user.id}/"
        
        begin
          objects = client.list_objects_v2(
            bucket: bucket_name,
            prefix: user_prefix
          )
          
          if objects.contents.any?
            Rails.logger.info "🗑️ Deleting #{objects.contents.count} existing avatar(s)"
            objects.contents.each do |object|
              Rails.logger.info "🗑️ Deleting #{object.key}"
              client.delete_object(bucket: bucket_name, key: object.key)
            end
          else
            Rails.logger.info "📝 No existing avatars found"
          end
        rescue => e
          Rails.logger.warn "⚠️ Error checking/deleting existing avatars: #{e.message}"
        end
        
        # Upload the new avatar
        Rails.logger.info "⬆️ Uploading to R2"
        client.put_object(
          bucket: bucket_name,
          key: r2_key,
          body: avatar_file.tempfile,
          content_type: avatar_file.content_type || 'image/jpeg'
        )
        
        # Generate the public URL
        public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 'https://pub-63612670c2d64075820ce8724feff8ea.r2.dev'
        "#{public_base}/#{r2_key}"
      end

      def delete_avatar_from_r2(user)
        require 'aws-sdk-s3'
        
        client = Aws::S3::Client.new(
          access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
          secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
          region: 'auto',
          endpoint: ENV['CLOUDFLARE_R2_ENDPOINT'] || 'https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com',
          force_path_style: true
        )

        bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
        
        # List all objects in the user's avatar folder
        user_prefix = "avatars/#{user.id}/"
        
        objects = client.list_objects_v2(
          bucket: bucket_name,
          prefix: user_prefix
        )
        
        # Delete all objects in the user's folder
        objects.contents.each do |object|
          Rails.logger.info "🗑️ Deleting #{object.key}"
          client.delete_object(bucket: bucket_name, key: object.key)
        end
        
        Rails.logger.info "✅ User avatar folder cleared"
      rescue => e
        Rails.logger.error "❌ Error deleting avatar from R2: #{e.message}"
      end
    end
  end
end
