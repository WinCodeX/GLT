# config/initializers/r2_compatibility_fix.rb
# Fixed R2 compatibility with valid AWS SDK options only

Rails.application.configure do
  if config.active_storage.service == :cloudflare
    Rails.logger.info "🔧 Configuring R2 compatibility..."
    
    # Configure AWS SDK globally for R2 compatibility (only valid options)
    config.to_prepare do
      Aws.config.update(
        # Only use options that exist in this AWS SDK version
        force_path_style: true,
        ssl_verify_peer: true,
        # Remove invalid options: compute_checksums, validate_checksums
        signature_version: 'v4'
      )
      
      # Only patch after Active Storage is loaded
      if defined?(ActiveStorage::Service::S3Service)
        Rails.logger.info "✅ Patching Active Storage S3Service for R2..."
        
        ActiveStorage::Service::S3Service.class_eval do
          # Override upload methods to remove conflicting checksums
          def upload_with_single_part(key, io, checksum: nil, **options)
            instrument :upload, key: key, checksum: checksum do |payload|
              # Use put_object directly with minimal parameters for R2
              @client.put_object(
                bucket: @bucket.name,
                key: key,
                body: io,
                content_type: options[:content_type],
                content_disposition: options[:disposition],
                content_encoding: options[:content_encoding],
                metadata: options[:custom_metadata] || {}
                # Deliberately omit checksum parameters that cause conflicts
              )
            end
          end
          
          # Override multipart upload to avoid checksum issues
          def upload_with_multipart(key, io, checksum: nil, **options)
            part_size = 10.megabytes
            
            # Initiate multipart upload without checksums
            response = @client.create_multipart_upload(
              bucket: @bucket.name,
              key: key,
              content_type: options[:content_type],
              content_disposition: options[:disposition],
              metadata: options[:custom_metadata] || {}
            )
            
            upload_id = response.upload_id
            parts = []
            part_number = 1
            
            begin
              io.rewind
              while (part = io.read(part_size))
                part_response = @client.upload_part(
                  bucket: @bucket.name,
                  key: key,
                  part_number: part_number,
                  upload_id: upload_id,
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
              @client.complete_multipart_upload(
                bucket: @bucket.name,
                key: key,
                upload_id: upload_id,
                multipart_upload: { parts: parts }
              )
              
            rescue => e
              # Abort failed upload
              @client.abort_multipart_upload(
                bucket: @bucket.name,
                key: key,
                upload_id: upload_id
              )
              raise e
            end
          end
        end
        
        Rails.logger.info "✅ R2 compatibility patches applied successfully"
      end
    end
  end
end