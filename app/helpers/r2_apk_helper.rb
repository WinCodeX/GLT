# app/helpers/r2_apk_helper.rb
module R2ApkHelper
  
  def list_r2_apk_versions
    return [] unless Rails.env.production?
    
    begin
      client = r2_client
      bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
      
      # List all version folders in AppUpdate/
      response = client.list_objects_v2(
        bucket: bucket_name,
        prefix: 'AppUpdate/',
        delimiter: '/'
      )
      
      versions = response.common_prefixes.map do |prefix|
        # Extract version from "AppUpdate/1.4.0/" -> "1.4.0"
        prefix.prefix.split('/')[1]
      end.compact.sort_by { |v| Gem::Version.new(v) rescue Gem::Version.new('0.0.0') }.reverse
      
      Rails.logger.info "Found #{versions.length} APK versions in R2: #{versions}"
      versions
    rescue => e
      Rails.logger.error "Failed to list R2 APK versions: #{e.message}"
      []
    end
  end
  
  def list_r2_apks_for_version(version)
    return [] unless Rails.env.production?
    
    begin
      client = r2_client
      bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
      
      response = client.list_objects_v2(
        bucket: bucket_name,
        prefix: "AppUpdate/#{version}/",
        max_keys: 10
      )
      
      apks = response.contents.filter_map do |object|
        next unless object.key.end_with?('.apk')
        
        {
          key: object.key,
          filename: File.basename(object.key),
          size: object.size,
          last_modified: object.last_modified,
          url: generate_r2_public_url(object.key)
        }
      end
      
      Rails.logger.info "Found #{apks.length} APK files for version #{version}"
      apks
    rescue => e
      Rails.logger.error "Failed to list R2 APKs for version #{version}: #{e.message}"
      []
    end
  end
  
  def r2_apk_exists?(version, filename)
    return false unless Rails.env.production?
    
    begin
      client = r2_client
      bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
      object_key = "AppUpdate/#{version}/#{filename}"
      
      client.head_object(bucket: bucket_name, key: object_key)
      true
    rescue Aws::S3::Errors::NotFound
      false
    rescue => e
      Rails.logger.error "Error checking R2 APK existence: #{e.message}"
      false
    end
  end
  
  def upload_apk_to_r2(file, version, key = nil)
    key ||= SecureRandom.uuid
    
    begin
      client = r2_client
      bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
      filename = file.original_filename
      object_key = "AppUpdate/#{version}/#{filename}"
      
      client.put_object(
        bucket: bucket_name,
        key: object_key,
        body: file.read,
        content_type: 'application/vnd.android.package-archive',
        metadata: {
          'version' => version,
          'upload_key' => key,
          'original_filename' => filename,
          'uploaded_at' => Time.current.iso8601,
          'uploader' => 'admin_panel'
        }
      )
      
      url = generate_r2_public_url(object_key)
      
      Rails.logger.info "APK uploaded to R2: #{object_key} (#{file.size} bytes)"
      
      {
        success: true,
        key: key,
        url: url,
        size: file.size,
        filename: filename,
        object_key: object_key
      }
    rescue => e
      Rails.logger.error "Failed to upload APK to R2: #{e.message}"
      
      {
        success: false,
        error: e.message
      }
    end
  end
  
  def delete_apk_from_r2(version, filename = nil)
    return false unless Rails.env.production?
    
    begin
      client = r2_client
      bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
      
      if filename
        # Delete specific file
        object_key = "AppUpdate/#{version}/#{filename}"
        client.delete_object(bucket: bucket_name, key: object_key)
        Rails.logger.info "Deleted APK from R2: #{object_key}"
      else
        # Delete all APKs in version folder
        response = client.list_objects_v2(
          bucket: bucket_name,
          prefix: "AppUpdate/#{version}/"
        )
        
        response.contents.each do |object|
          if object.key.end_with?('.apk')
            client.delete_object(bucket: bucket_name, key: object.key)
            Rails.logger.info "Deleted APK from R2: #{object.key}"
          end
        end
      end
      
      true
    rescue => e
      Rails.logger.error "Failed to delete APK from R2: #{e.message}"
      false
    end
  end
  
  def sync_database_with_r2
    return unless Rails.env.production?
    
    begin
      r2_versions = list_r2_apk_versions
      db_versions = AppUpdate.pluck(:version)
      
      # Find versions in R2 but not in database
      missing_in_db = r2_versions - db_versions
      
      missing_in_db.each do |version|
        apks = list_r2_apks_for_version(version)
        
        if apks.any?
          apk = apks.first # Take the first APK found
          
          # Create database record for R2 APK
          AppUpdate.create!(
            version: version,
            apk_url: apk[:url],
            apk_key: SecureRandom.uuid,
            apk_size: apk[:size],
            apk_filename: apk[:filename],
            runtime_version: '1.0.0',
            published: false,
            changelog: ["Synced from R2 storage"]
          )
          
          Rails.logger.info "Created database record for R2 APK: #{version}"
        end
      end
      
      # Find versions in database but not in R2
      missing_in_r2 = db_versions - r2_versions
      
      if missing_in_r2.any?
        Rails.logger.warn "Database versions missing from R2: #{missing_in_r2}"
      end
      
    rescue => e
      Rails.logger.error "Failed to sync database with R2: #{e.message}"
    end
  end
  
  def get_apk_download_stats
    begin
      total_downloads = AppUpdate.sum(:download_count) || 0
      total_apks = AppUpdate.count
      published_apks = AppUpdate.where(published: true).count
      total_size = AppUpdate.sum(:apk_size) || 0
      
      {
        total_downloads: total_downloads,
        total_apks: total_apks,
        published_apks: published_apks,
        total_size_mb: (total_size.to_f / 1.megabyte).round(2),
        average_size_mb: total_apks > 0 ? ((total_size.to_f / total_apks) / 1.megabyte).round(2) : 0
      }
    rescue => e
      Rails.logger.error "Failed to get APK download stats: #{e.message}"
      {
        total_downloads: 0,
        total_apks: 0,
        published_apks: 0,
        total_size_mb: 0,
        average_size_mb: 0
      }
    end
  end
  
  private
  
  def r2_client
    require 'aws-sdk-s3'
    
    Aws::S3::Client.new(
      access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
      secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
      region: 'auto',
      endpoint: ENV['CLOUDFLARE_R2_ENDPOINT'] || 'https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com',
      force_path_style: true
    )
  end
  
  def generate_r2_public_url(object_key)
    public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 'https://pub-63612670c2d64075820ce8724feff8ea.r2.dev'
    "#{public_base}/#{object_key}"
  end
end