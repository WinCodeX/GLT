# app/controllers/api/v1/me_controller.rb - SIMPLE WORKING VERSION
module Api
  module V1
    class MeController < ApplicationController
      before_action :authenticate_user!

      def show
        render json: { 
          id: current_user.id, 
          email: current_user.email,
          avatar_url: simple_avatar_url,
          avatar_attached: current_user.avatar.attached?,
          debug_info: Rails.env.development? ? debug_avatar_info : nil
        }.compact
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
          
          # Simple approach - let Rails handle everything
          current_user.avatar.purge if current_user.avatar.attached?
          current_user.avatar.attach(avatar_file)
          
          # Force reload to ensure attachment is saved
          current_user.reload
          
          unless current_user.avatar.attached?
            raise "Avatar attachment failed - not attached after save"
          end
          
          Rails.logger.info "✅ Avatar attached successfully"
          Rails.logger.info "🔗 Generated URL: #{simple_avatar_url}"
          
          render json: {
            success: true,
            message: 'Avatar updated successfully',
            avatar_url: simple_avatar_url,
            avatar_attached: current_user.avatar.attached?
          }
          
        rescue => e
          Rails.logger.error "❌ Avatar upload error: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.first(10).join("\n")
          
          render json: { 
            success: false,
            error: "Upload failed: #{e.message}",
            error_class: e.class.to_s
          }, status: :unprocessable_entity
        end
      end

      def destroy_avatar
        begin
          current_user.avatar.purge if current_user.avatar.attached?
          current_user.reload
          
          Rails.logger.info "🗑️ Avatar deleted for user #{current_user.id}"
          
          render json: { 
            success: true, 
            message: 'Avatar deleted',
            avatar_url: nil
          }
        rescue => e
          Rails.logger.error "❌ Avatar deletion error: #{e.message}"
          render json: { 
            success: false, 
            error: 'Deletion failed' 
          }, status: :unprocessable_entity
        end
      end

      # Debug endpoint
      def avatar_debug
        return head :forbidden unless Rails.env.development?
        
        render json: debug_avatar_info
      end

      private

      def simple_avatar_url
        return nil unless current_user.avatar.attached?
        
        begin
          if Rails.env.production?
            # Production: Generate R2 public URL
            public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL']
            
            if public_base.blank?
              Rails.logger.error "CLOUDFLARE_R2_PUBLIC_URL not configured!"
              return nil
            end
            
            # Get the blob key that was just uploaded
            blob_key = current_user.avatar.blob.key
            Rails.logger.info "🔗 Generating R2 URL with key: #{blob_key}"
            
            url = "#{public_base}/#{blob_key}"
            Rails.logger.info "🔗 Final avatar URL: #{url}"
            return url
            
          else
            # Development: simple Rails URL
            base_url = "#{request.protocol}#{request.host_with_port}"
            "#{base_url}#{rails_blob_path(current_user.avatar)}"
          end
        rescue => e
          Rails.logger.error "❌ Avatar URL generation failed: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          nil
        end
      end

      def debug_avatar_info
        {
          user_id: current_user.id,
          environment: Rails.env,
          storage_service: Rails.application.config.active_storage.service,
          avatar_attached: current_user.avatar.attached?,
          avatar_details: current_user.avatar.attached? ? {
            filename: current_user.avatar.filename.to_s,
            content_type: current_user.avatar.content_type,
            byte_size: current_user.avatar.byte_size,
            blob_key: current_user.avatar.blob.key,
            service_name: current_user.avatar.blob.service_name,
            created_at: current_user.avatar.created_at
          } : "No avatar attached",
          generated_url: simple_avatar_url,
          request_info: {
            protocol: request.protocol,
            host_with_port: request.host_with_port,
            base_url: "#{request.protocol}#{request.host_with_port}"
          },
          active_storage_config: {
            service: Rails.application.config.active_storage.service,
            routes_enabled: Rails.application.config.active_storage.draw_routes
          }
        }
      end
    end
  end
end