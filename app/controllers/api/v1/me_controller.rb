# app/controllers/api/v1/me_controller.rb - Enhanced with ActionCable broadcasting for real-time profile updates

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
          
          # ENHANCED: Broadcast profile updates to all connected clients
          broadcast_profile_update(user_data)
          
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
          
          # Store old avatar URL for broadcasting
          old_avatar_url = avatar_api_url(current_user)
          
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
          
          # ENHANCED: Broadcast avatar change to all connected clients
          broadcast_avatar_change(new_avatar_url, old_avatar_url)
          
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
        # Store old avatar URL for broadcasting
        old_avatar_url = avatar_api_url(current_user)
        
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
        
        # ENHANCED: Broadcast avatar deletion to all connected clients
        broadcast_avatar_change(user_data[:avatar_url], old_avatar_url)
        
        render json: { 
          success: true, 
          message: 'Avatar deleted',
          avatar_url: user_data[:avatar_url],
          user: user_data
        }
      end

      private

      # ENHANCED: Broadcast profile updates via ActionCable
      def broadcast_profile_update(user_data)
        begin
          # Broadcast to user's personal channel
          ActionCable.server.broadcast(
            "user_notifications_#{current_user.id}",
            {
              type: 'profile_updated',
              user_id: current_user.id,
              user_data: user_data.except(:sensitive_fields),
              timestamp: Time.current.iso8601
            }
          )
          
          # Broadcast to global user updates channel for other users who might display this user
          ActionCable.server.broadcast(
            "user_profile_updates",
            {
              type: 'user_profile_changed',
              user_id: current_user.id,
              name: user_data[:full_name] || user_data[:name],
              email: user_data[:email],
              avatar_url: user_data[:avatar_url],
              timestamp: Time.current.iso8601
            }
          )
          
          Rails.logger.info "📡 Profile update broadcast sent for user #{current_user.id}"
        rescue => e
          Rails.logger.error "❌ Failed to broadcast profile update: #{e.message}"
        end
      end

      # ENHANCED: Broadcast avatar changes via ActionCable
      def broadcast_avatar_change(new_avatar_url, old_avatar_url)
        begin
          # Broadcast to user's personal channel
          ActionCable.server.broadcast(
            "user_notifications_#{current_user.id}",
            {
              type: 'avatar_updated',
              user_id: current_user.id,
              avatar_url: new_avatar_url,
              previous_avatar_url: old_avatar_url,
              timestamp: Time.current.iso8601
            }
          )
          
          # Broadcast to global avatar updates channel for immediate UI updates
          ActionCable.server.broadcast(
            "user_avatar_updates",
            {
              type: 'avatar_changed',
              user_id: current_user.id,
              avatar_url: new_avatar_url,
              user_name: current_user.full_name.presence || current_user.email,
              timestamp: Time.current.iso8601
            }
          )
          
          # Broadcast to any businesses where this user is involved
          broadcast_avatar_to_businesses(new_avatar_url)
          
          Rails.logger.info "📡 Avatar change broadcast sent for user #{current_user.id}"
        rescue => e
          Rails.logger.error "❌ Failed to broadcast avatar change: #{e.message}"
        end
      end

      # ENHANCED: Broadcast avatar changes to business channels
      def broadcast_avatar_to_businesses(new_avatar_url)
        begin
          # Find businesses where user is owner or staff
          business_ids = []
          
          # Add owned businesses
          if current_user.respond_to?(:owned_businesses)
            business_ids += current_user.owned_businesses.pluck(:id)
          end
          
          # Add businesses where user is staff
          if current_user.respond_to?(:user_businesses)
            business_ids += current_user.user_businesses.pluck(:business_id)
          end
          
          # Broadcast to each business channel
          business_ids.uniq.each do |business_id|
            ActionCable.server.broadcast(
              "business_#{business_id}_updates",
              {
                type: 'member_avatar_changed',
                user_id: current_user.id,
                avatar_url: new_avatar_url,
                user_name: current_user.full_name.presence || current_user.email,
                timestamp: Time.current.iso8601
              }
            )
          end
          
          Rails.logger.info "📡 Avatar change broadcast sent to #{business_ids.count} business channels"
        rescue => e
          Rails.logger.error "❌ Failed to broadcast avatar to businesses: #{e.message}"
        end
      end

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