# config/initializers/r2_compatibility_fix.rb
# Complete fix for Cloudflare R2 checksum compatibility with Active Storage

Rails.application.configure do
  # Apply R2 fixes when using cloudflare storage
  if config.active_storage.service == :cloudflare
    Rails.logger.info "🔧 Applying comprehensive R2 compatibility fixes..."
    
    # Configure AWS SDK for R2 compatibility
    Aws.config.update(
      # Disable automatic checksum computation
      compute_checksums: false,
      # Disable request signing validation that can conflict  
      validate_checksums: false,
      # Enable path style for R2
      force_path_style: true,
      # Disable SSL verification issues
      ssl_verify_peer: true
    )
    
    # Patch Active Storage S3 Service for R2
    ActiveStorage::Service::S3Service.class_eval do
      # Override upload methods to remove conflicting checksums
      def upload_with_single_part(key, io, checksum: nil, **options)
        instrument :upload, key: key, checksum: checksum do |payload|
          object_for(key).put(
            body: io,
            # Remove all checksum-related parameters that conflict with R2
            content_type: options[:content_type],
            content_disposition: options[:disposition],
            content_encoding: options[:content_encoding],
            content_language: options[:content_language],
            expires: options[:expires],
            cache_control: options[:cache_control],
            metadata: options[:custom_metadata] || {}
            # Note: Deliberately omitting any checksum parameters
          )
        end
      end
      
      # Override multipart upload for R2 compatibility
      def upload_with_multipart(key, io, checksum: nil, **options)
        part_size = upload_part_size
        
        upload = object_for(key).initiate_multipart_upload(
          content_type: options[:content_type],
          content_disposition: options[:disposition],
          content_encoding: options[:content_encoding],
          content_language: options[:content_language],
          expires: options[:expires],
          cache_control: options[:cache_control],
          metadata: options[:custom_metadata] || {}
          # Note: No checksum parameters for R2 compatibility
        )
        
        parts = []
        part_number = 1
        
        io.rewind
        while (part = io.read(part_size))
          part_upload = upload.part(part_number)
          
          # Upload part without checksum conflicts
          part_response = part_upload.upload(
            body: part
            # No checksum parameters
          )
          
          parts << {
            part_number: part_number,
            etag: part_response.etag
          }
          
          part_number += 1
        end
        
        # Complete multipart upload
        upload.complete(
          multipart_upload: {
            parts: parts
          }
        )
      rescue => e
        # Clean up failed upload
        upload&.abort
        raise e
      end
      
      private
      
      def upload_part_size
        # Use 10MB parts for better R2 compatibility
        10.megabytes
      end
    end
    
    Rails.logger.info "✅ R2 compatibility fixes applied successfully"
  end
end