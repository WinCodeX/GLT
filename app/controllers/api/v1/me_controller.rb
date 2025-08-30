# app/controllers/api/v1/me_controller.rb
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

        begin
          Rails.logger.info "🖼️ Starting avatar upload for user #{current_user.id}"
          
          # Remove existing avatar
          current_user.avatar.purge if current_user.avatar.attached?
          
          # Upload to R2 via Active Storage (now using cloudflare service)
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
          render json: { 
            success: false,
            error: "Upload failed: #{e.message}"
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
        user_data[:avatar_url] = avatar_api_url(current_user) # This will now return fallback
        
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