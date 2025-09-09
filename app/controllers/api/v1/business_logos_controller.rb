# app/controllers/api/v1/business_logos_controller.rb
module Api
  module V1
    class BusinessLogosController < ApplicationController
      before_action :authenticate_user!
      before_action :set_business
      before_action :authorize_business_owner

      def create
        begin
          Rails.logger.info "Starting business logo upload for business #{@business.id}, owner #{current_user.id}"
          
          uploaded_file = params[:logo]
          
          unless uploaded_file.present?
            return render json: {
              success: false,
              message: 'No logo file provided'
            }, status: :unprocessable_entity
          end

          # Validate file type
          unless valid_image_type?(uploaded_file.content_type)
            return render json: {
              success: false,
              message: 'Invalid file type. Please upload a valid image (JPEG, PNG, GIF, WebP)'
            }, status: :unprocessable_entity
          end

          # Validate file size (5MB max)
          max_size = 5.megabytes
          if uploaded_file.size > max_size
            return render json: {
              success: false,
              message: 'File too large. Maximum size is 5MB'
            }, status: :unprocessable_entity
          end

          # Process and save logo
          logo_url = save_business_logo(uploaded_file)
          
          Rails.logger.info "Business logo saved successfully: #{logo_url}"
          
          render json: {
            success: true,
            message: 'Business logo uploaded successfully',
            data: {
              logo_url: logo_url,
              business: {
                id: @business.id,
                name: @business.name,
                logo_url: logo_url
              }
            }
          }, status: :ok

        rescue StandardError => e
          Rails.logger.error "Business logo upload error: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          render json: {
            success: false,
            message: 'Failed to upload business logo',
            errors: ['An unexpected error occurred. Please try again.']
          }, status: :internal_server_error
        end
      end

      def show
        logo_url = @business.logo_url
        
        if logo_url
          render json: {
            success: true,
            data: { logo_url: logo_url }
          }, status: :ok
        else
          render json: {
            success: false,
            message: 'No logo found for this business'
          }, status: :not_found
        end
      end

      def destroy
        begin
          deleted = delete_business_logo
          
          if deleted
            Rails.logger.info "Business logo deleted successfully for business #{@business.id}"
            render json: {
              success: true,
              message: 'Business logo deleted successfully'
            }, status: :ok
          else
            render json: {
              success: false,
              message: 'No logo found to delete'
            }, status: :not_found
          end

        rescue StandardError => e
          Rails.logger.error "Business logo deletion error: #{e.class} - #{e.message}"
          render json: {
            success: false,
            message: 'Failed to delete business logo',
            errors: ['An unexpected error occurred. Please try again.']
          }, status: :internal_server_error
        end
      end

      private

      def set_business
        @business = Business.includes(:categories, :owner).find(params[:business_id])
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: "Business not found" 
        }, status: :not_found
      end

      def authorize_business_owner
        unless @business.owner == current_user
          render json: { 
            success: false, 
            message: "Only business owner can manage business logo" 
          }, status: :forbidden
        end
      end

      def valid_image_type?(content_type)
        %w[image/jpeg image/png image/gif image/webp].include?(content_type)
      end

      def save_business_logo(uploaded_file)
        if Rails.env.production?
          save_logo_to_r2(uploaded_file)
        else
          save_logo_locally(uploaded_file)
        end
      end

      def save_logo_to_r2(uploaded_file)
        require 'aws-sdk-s3'
        
        client = Aws::S3::Client.new(
          access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
          secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
          region: 'auto',
          endpoint: ENV['CLOUDFLARE_R2_ENDPOINT'] || 'https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com',
          force_path_style: true
        )

        bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
        
        # Determine file extension
        extension = case uploaded_file.content_type
                   when 'image/jpeg' then '.jpg'
                   when 'image/png' then '.png'
                   when 'image/gif' then '.gif'
                   when 'image/webp' then '.webp'
                   else '.jpg'
                   end

        # Create unique key for business logo
        logo_key = "businesslogo/#{current_user.id}/#{@business.id}/logo#{extension}"
        
        Rails.logger.info "Uploading business logo to R2: #{logo_key}"

        # Read file content
        file_content = uploaded_file.read
        uploaded_file.rewind

        # Upload to R2
        client.put_object(
          bucket: bucket_name,
          key: logo_key,
          body: file_content,
          content_type: uploaded_file.content_type,
          metadata: {
            'uploaded_by' => current_user.id.to_s,
            'business_id' => @business.id.to_s,
            'uploaded_at' => Time.current.iso8601
          }
        )

        # Return public URL
        public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 'https://pub-63612670c2d64075820ce8724feff8ea.r2.dev'
        "#{public_base}/#{logo_key}"
      end

      def save_logo_locally(uploaded_file)
        # Create directory if it doesn't exist
        logo_dir = Rails.root.join('public', 'uploads', 'businesslogo', current_user.id.to_s, @business.id.to_s)
        FileUtils.mkdir_p(logo_dir)

        # Determine file extension
        extension = case uploaded_file.content_type
                   when 'image/jpeg' then '.jpg'
                   when 'image/png' then '.png'
                   when 'image/gif' then '.gif'
                   when 'image/webp' then '.webp'
                   else '.jpg'
                   end

        # Save file
        logo_path = logo_dir.join("logo#{extension}")
        
        # Remove existing logo files
        Dir.glob(logo_dir.join("logo.*")).each { |f| File.delete(f) }
        
        File.open(logo_path, 'wb') do |file|
          file.write(uploaded_file.read)
        end

        # Return relative URL
        "/uploads/businesslogo/#{current_user.id}/#{@business.id}/logo#{extension}"
      end

      def delete_business_logo
        if Rails.env.production?
          delete_logo_from_r2
        else
          delete_logo_locally
        end
      end

      def delete_logo_from_r2
        require 'aws-sdk-s3'
        
        client = Aws::S3::Client.new(
          access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
          secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
          region: 'auto',
          endpoint: ENV['CLOUDFLARE_R2_ENDPOINT'] || 'https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com',
          force_path_style: true
        )

        bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
        logo_prefix = "businesslogo/#{current_user.id}/#{@business.id}/"
        
        # List and delete all logo files
        response = client.list_objects_v2(
          bucket: bucket_name,
          prefix: logo_prefix
        )
        
        deleted_any = false
        response.contents.each do |object|
          client.delete_object(bucket: bucket_name, key: object.key)
          deleted_any = true
        end
        
        deleted_any
      end

      def delete_logo_locally
        logo_dir = Rails.root.join('public', 'uploads', 'businesslogo', current_user.id.to_s, @business.id.to_s)
        return false unless Dir.exist?(logo_dir)
        
        deleted_any = false
        Dir.glob(logo_dir.join("logo.*")).each do |file_path|
          File.delete(file_path)
          deleted_any = true
        end
        
        deleted_any
      end
    end
  end
end