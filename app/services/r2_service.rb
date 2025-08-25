# app/services/r2_service.rb
# Custom Active Storage service specifically for Cloudflare R2

class R2Service < ActiveStorage::Service::S3Service
  def initialize(bucket:, access_key_id:, secret_access_key:, region:, endpoint:, **options)
    # Configure AWS client specifically for R2
    @client = Aws::S3::Client.new(
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      region: region,
      endpoint: endpoint,
      force_path_style: true,
      # R2-specific settings
      compute_checksums: false,
      validate_checksums: false,
      http_wire_trace: false
    )
    
    @bucket = bucket
    @multipart_upload_threshold = options[:multipart_upload_threshold] || 100.megabytes
    @public = options.fetch(:public, false)
  end

  # Override upload to remove checksum conflicts
  def upload(key, io, checksum: nil, content_type: nil, disposition: nil, filename: nil, custom_metadata: {})
    instrument :upload, key: key do |payload|
      if io.size < @multipart_upload_threshold
        upload_with_single_part(key, io, content_type: content_type, disposition: disposition, custom_metadata: custom_metadata)
      else
        upload_with_multipart(key, io, content_type: content_type, disposition: disposition, custom_metadata: custom_metadata)
      end
    end
  end

  private

  def upload_with_single_part(key, io, content_type: nil, disposition: nil, custom_metadata: {})
    object_for(key).put(
      body: io,
      content_type: content_type,
      content_disposition: disposition,
      metadata: custom_metadata
      # Deliberately omit all checksum parameters for R2 compatibility
    )
  end

  def upload_with_multipart(key, io, content_type: nil, disposition: nil, custom_metadata: {})
    part_size = 10.megabytes
    
    upload = object_for(key).initiate_multipart_upload(
      content_type: content_type,
      content_disposition: disposition,
      metadata: custom_metadata
      # No checksum parameters
    )
    
    parts = []
    part_number = 1
    
    io.rewind
    while (part = io.read(part_size))
      part_response = upload.part(part_number).upload(body: part)
      
      parts << {
        part_number: part_number,
        etag: part_response.etag
      }
      
      part_number += 1
    end
    
    upload.complete(multipart_upload: { parts: parts })
    
  rescue => e
    upload&.abort
    raise e
  end

  def object_for(key)
    @bucket.object(key)
  end

  def bucket
    @bucket ||= @client.bucket(@bucket) if @bucket.is_a?(String)
    @bucket ||= Aws::S3::Bucket.new(@bucket, client: @client)
  end
end