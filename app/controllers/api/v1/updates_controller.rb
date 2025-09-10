# app/controllers/api/v1/updates_controller.rb - Fixed to always return JSON

class Api::V1::UpdatesController < ApplicationController
  # Ensure we always respond with JSON
  before_action :set_json_format
  before_action :authenticate_user_json!, except: [:manifest, :info, :check, :download]
  before_action :ensure_admin!, only: [:create, :publish, :upload_apk]

  def index
    # Return list of updates (admin only or published for regular users)
    if current_user&.admin?
      @updates = AppUpdate.all.order(created_at: :desc)
    else
      @updates = AppUpdate.published.order(created_at: :desc)
    end

    render json: @updates.map { |update|
      {
        id: update.id,
        version: update.version,
        runtime_version: update.runtime_version,
        description: update.description,
        changelog: update.changelog,
        force_update: update.force_update,
        published: update.published,
        apk_url: update.apk_url,
        apk_size: update.apk_size,
        download_count: update.download_count,
        created_at: update.created_at,
        published_at: update.published_at
      }
    }
  end

  def manifest
    # Legacy endpoint - now returns APK update info instead of Expo manifest
    latest_update = AppUpdate.published.latest
    
    if latest_update
      render json: {
        id: latest_update.update_id,
        createdAt: latest_update.created_at.iso8601,
        runtimeVersion: latest_update.runtime_version,
        apkAsset: {
          key: latest_update.apk_key,
          contentType: 'application/vnd.android.package-archive',
          url: latest_update.apk_url,
          size: latest_update.apk_size
        },
        metadata: {
          version: latest_update.version,
          changelog: latest_update.changelog,
          force_update: latest_update.force_update
        }
      }
    else
      render json: { error: 'No updates available' }, status: 404
    end
  end

  def info
    # Get latest APK update information
    latest_update = AppUpdate.published.latest
    current_version = params[:current_version] || '1.0.0'
    
    if latest_update && version_greater_than?(latest_update.version, current_version)
      render json: {
        available: true,
        version: latest_update.version,
        changelog: latest_update.changelog,
        release_date: latest_update.created_at.iso8601,
        force_update: latest_update.force_update,
        download_url: latest_update.apk_url,
        file_size: latest_update.apk_size
      }
    else
      render json: {
        available: false,
        current_version: current_version
      }
    end
  end

  def check
    # Check if APK updates are available for specific version
    current_version = params[:version] || '1.0.0'
    latest_update = AppUpdate.published.latest
    
    has_update = latest_update && version_greater_than?(latest_update.version, current_version)
    
    render json: {
      has_update: has_update,
      latest_version: latest_update&.version,
      current_version: current_version,
      force_update: has_update ? latest_update.force_update : false,
      file_size: has_update ? latest_update.apk_size : nil
    }
  end

  def download
    # Direct APK download endpoint with download tracking
    update = if params[:version]
      AppUpdate.published.find_by(version: params[:version])
    else
      AppUpdate.published.latest
    end
    
    unless update
      render json: { error: 'Update not found' }, status: 404
      return
    end
    
    unless update.apk_url.present?
      render json: { error: 'APK file not available' }, status: 404
      return
    end
    
    # Increment download count
    update.increment_download_count!
    
    # Redirect to actual APK download URL
    redirect_to update.apk_url, allow_other_host: true
  end

  def create
    @update = AppUpdate.new(update_params)
    @update.update_id = SecureRandom.uuid
    
    # Handle APK file upload if present
    if params[:apk].present?
      begin
        apk_result = upload_apk_file(params[:apk], @update.version)
        @update.apk_url = apk_result[:apk_url]
        @update.apk_key = apk_result[:apk_key]
        @update.apk_size = apk_result[:size]
      rescue => e
        Rails.logger.error "APK upload failed: #{e.message}"
        render json: { 
          error: "APK upload failed", 
          details: e.message 
        }, status: 500
        return
      end
    end
    
    if @update.save
      render json: {
        id: @update.id,
        version: @update.version,
        runtime_version: @update.runtime_version,
        description: @update.description,
        changelog: @update.changelog,
        force_update: @update.force_update,
        published: @update.published,
        apk_url: @update.apk_url,
        apk_size: @update.apk_size,
        created_at: @update.created_at
      }, status: :created
    else
      render json: { 
        error: 'Validation failed',
        errors: @update.errors.full_messages 
      }, status: :unprocessable_entity
    end
  end

  def publish
    @update = AppUpdate.find(params[:id])
    
    if @update.update(published: true, published_at: Time.current)
      render json: {
        id: @update.id,
        version: @update.version,
        published: @update.published,
        published_at: @update.published_at,
        message: 'Update published successfully'
      }
    else
      render json: { 
        error: 'Failed to publish update',
        errors: @update.errors.full_messages 
      }, status: :unprocessable_entity
    end
  end

  def upload_bundle
    # Legacy endpoint for bundle uploads (now handles APK uploads)
    unless params[:apk].present?
      render json: { error: 'No APK file provided' }, status: 400
      return
    end
    
    begin
      version = params[:version] || '1.0.0'
      result = upload_apk_file(params[:apk], version)
      
      render json: {
        success: true,
        apk_key: result[:apk_key],
        apk_url: result[:apk_url],
        size: result[:size],
        version: version
      }
    rescue => e
      Rails.logger.error "APK upload failed: #{e.message}"
      render json: { 
        error: "APK upload failed", 
        details: e.message 
      }, status: 500
    end
  end

  private

  def set_json_format
    request.format = :json
  end

  def authenticate_user_json!
    unless user_signed_in?
      render json: { 
        error: 'Authentication required',
        message: 'Please sign in to access this resource'
      }, status: 401
      return
    end
  end

  def ensure_admin!
    unless current_user&.admin?
      render json: { 
        error: 'Unauthorized',
        message: 'Admin access required'
      }, status: 403
      return
    end
  end

  def update_params
    params.permit(:version, :runtime_version, :description, :force_update, :published, changelog: [])
  end

  def version_greater_than?(version1, version2)
    Gem::Version.new(version1) > Gem::Version.new(version2)
  rescue ArgumentError
    false
  end

  def upload_apk_file(file, version)
    # Validate file type
    unless file.content_type == 'application/vnd.android.package-archive' || 
           file.original_filename&.end_with?('.apk')
      raise 'Invalid file type. Please upload an APK file.'
    end

    # Validate file size (200MB limit)
    max_size = 200.megabytes
    if file.size > max_size
      raise "File too large. Maximum size is #{max_size / 1.megabyte}MB."
    end

    apk_key = SecureRandom.uuid
    
    if Rails.env.production?
      apk_url = upload_apk_to_r2(file, apk_key, version)
    else
      apk_url = upload_apk_to_local(file, apk_key, version)
    end
    
    {
      apk_key: apk_key,
      apk_url: apk_url,
      size: file.size
    }
  end

  def upload_apk_to_r2(file, key, version)
    require 'aws-sdk-s3'
    
    client = Aws::S3::Client.new(
      access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
      secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
      region: 'auto',
      endpoint: ENV['CLOUDFLARE_R2_ENDPOINT'] || 'https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com',
      force_path_style: true
    )

    bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
    object_key = "AppUpdate/#{version}/#{key}.apk"
    
    obj = client.put_object(
      bucket: bucket_name,
      key: object_key,
      body: file.read,
      content_type: 'application/vnd.android.package-archive',
      metadata: {
        'version' => version,
        'upload_key' => key,
        'original_filename' => file.original_filename
      }
    )
    
    public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 'https://pub-63612670c2d64075820ce8724feff8ea.r2.dev'
    "#{public_base}/#{object_key}"
  end

  def upload_apk_to_local(file, key, version)
    # Development/local storage
    filename = "#{key}.apk"
    upload_path = Rails.root.join('public', 'uploads', 'apks', version)
    FileUtils.mkdir_p(upload_path)
    
    file_path = upload_path.join(filename)
    File.open(file_path, 'wb') do |f|
      f.write(file.read)
    end
    
    "#{request.base_url}/uploads/apks/#{version}/#{filename}"
  end
end