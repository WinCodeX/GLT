# app/controllers/api/v1/me_controller.rb - FIXED: Avatar-only updates without touching other fields
module Api
  module V1
    class MeController < ApplicationController
      before_action :authenticate_user!

      include Rails.application.routes.url_helpers
      include UrlHostHelper

      def show
        render json: UserSerializer.new(current_user).serializable_hash
      end

      def update_avatar
        unless params[:avatar].present?
          return render json: { 
            success: false,
            error: 'No avatar file provided' 
          }, status: :bad_request
        end

        # Validate file type and size
        avatar_file = params[:avatar]
        
        unless valid_image_file?(avatar_file)
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
          
          # Remove existing avatar if present (this doesn't affect user model)
          if current_user.avatar.attached?
            Rails.logger.info "🗑️ Removing existing avatar"
            current_user.avatar.purge
          end

          # Attach new avatar (ActiveStorage handles persistence automatically)
          Rails.logger.info "📎 Attaching new avatar"
          current_user.avatar.attach(avatar_file)
          
          # ActiveStorage attachments are automatically persisted
          # No need to call user.save! which could trigger other field validations
          
          # Wait a brief moment for attachment to be processed
          sleep(0.1)
          
          # Verify attachment was successful
          if current_user.avatar.attached?
            Rails.logger.info "✅ Avatar attached successfully"
            
            # Generate avatar URL safely
            avatar_url = nil
            begin
              avatar_url = generate_avatar_url(current_user)
              Rails.logger.info "🔗 Avatar URL generated: #{avatar_url}"
            rescue => url_error
              Rails.logger.warn "⚠️ Could not generate avatar URL immediately: #{url_error.message}"
              # URL generation can fail immediately after upload, that's OK
            end
            
            # Return fresh user data without triggering full model save/validation
            render json: {
              success: true,
              message: 'Avatar updated successfully',
              avatar_url: avatar_url,
              user: UserSerializer.new(current_user).serializable_hash[:data][:attributes]
            }, status: :ok
          else
            Rails.logger.error "❌ Avatar attachment verification failed"
            render json: { 
              success: false,
              error: 'Avatar failed to attach properly' 
            }, status: :unprocessable_entity
          end

        rescue ActiveStorage::FileNotFoundError => e
          Rails.logger.error "❌ Avatar file not found: #{e.message}"
          render json: { 
            success: false,
            error: 'Avatar file could not be processed' 
          }, status: :unprocessable_entity
          
        rescue ActiveStorage::IntegrityError => e
          Rails.logger.error "❌ Avatar file integrity error: #{e.message}"
          render json: { 
            success: false,
            error: 'Avatar file appears to be corrupted' 
          }, status: :unprocessable_entity
          
        rescue => e
          Rails.logger.error "❌ Avatar upload error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          render json: { 
            success: false,
            error: 'Avatar upload failed',
            details: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def destroy_avatar
        begin
          if current_user.avatar.attached?
            Rails.logger.info "🗑️ Removing avatar for user #{current_user.id}"
            
            # Purge avatar (ActiveStorage handles this automatically)
            current_user.avatar.purge
            # No need to call user.save! since attachment deletion is automatic
            
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
            error: 'Failed to delete avatar',
            details: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      private

      def valid_image_file?(file)
        return false unless file.respond_to?(:content_type)
        
        allowed_types = ['image/jpeg', 'image/jpg', 'image/png', 'image/gif']
        allowed_types.include?(file.content_type.downcase)
      end

      def generate_avatar_url(user)
        return nil unless user.avatar.attached?

        # Check if attachment exists and is accessible
        begin
          # Try to access the blob to ensure it's properly attached
          blob = user.avatar.blob
          return nil unless blob
        rescue => e
          Rails.logger.warn "⚠️ Avatar blob not accessible: #{e.message}"
          return nil
        end

        host = first_available_host
        return nil unless host

        begin
          # Use rails_blob_url for reliable URL generation
          rails_blob_url(user.avatar, host: host, protocol: host.include?('https') ? 'https' : 'http')
        rescue => e
          Rails.logger.error "❌ Error generating avatar URL: #{e.message}"
          nil
        end
      end
    end
  end
end