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
          Rails.logger.info "🗄️ Active Storage Service: #{Rails.application.config.active_storage.service}"
          
          # Log environment variables for debugging
          Rails.logger.info "🔑 R2 Config Check:"
          Rails.logger.info "   - Bucket: #{ENV['CLOUDFLARE_R2_BUCKET']&.present? ? 'SET' : 'MISSING'}"
          Rails.logger.info "   - Access Key: #{ENV['CLOUDFLARE_R2_ACCESS_KEY_ID']&.present? ? 'SET' : 'MISSING'}"
          Rails.logger.info "   - Secret Key: #{ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY']&.present? ? 'SET' : 'MISSING'}"
          Rails.logger.info "   - Public URL: #{ENV['CLOUDFLARE_R2_PUBLIC_URL']&.present? ? 'SET' : 'MISSING'}"
          
          # Remove existing avatar
          if current_user.avatar.attached?
            Rails.logger.info "🗑️ Purging existing avatar"
            current_user.avatar.purge
          end
          
          # Create a proper IO object from the uploaded file
          io_object = if avatar_file.respond_to?(:tempfile)
            avatar_file.tempfile
          elsif avatar_file.respond_to?(:read)
            avatar_file
          else
            raise "Invalid file object: #{avatar_file.class}"
          end

          Rails.logger.info "📎 Attaching avatar via Active Storage"
          
          # Upload to R2 via Active Storage (now using cloudflare service)
          current_user.avatar.attach(
            io: io_object,
            filename: avatar_file.original_filename || 'avatar.jpg',
            content_type: avatar_file.content_type || 'image/jpeg'
          )
          
          # Verify attachment with detailed logging
          current_user.reload
          unless current_user.avatar.attached?
            Rails.logger.error "❌ Avatar attachment verification failed"
            raise "Avatar attachment failed - no avatar found after attach"
          end
          
          Rails.logger.info "✅ Avatar attachment verified"
          Rails.logger.info "🔗 Blob ID: #{current_user.avatar.blob.id}"
          Rails.logger.info "🔑 Blob Key: #{current_user.avatar.blob.key}"
          
          # Generate the proper avatar URL using controller method
          new_avatar_url = avatar_api_url(current_user)
          
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
        current_user.avatar.purge if current_user.avatar.attached?
        current_user.reload
        
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
    end
  end
end