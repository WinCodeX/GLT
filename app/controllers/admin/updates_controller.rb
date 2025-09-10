# app/controllers/admin/updates_controller.rb
class Admin::UpdatesController < AdminController
  before_action :set_update, only: [:show, :edit, :update, :destroy, :publish, :unpublish]
  
  # GET /admin/updates
  def index
    begin
      # Initialize with safe defaults
      @updates = []
      @stats = {
        total: 0,
        published: 0,
        draft: 0,
        total_downloads: 0
      }
      
      # Only query if table exists and is accessible
      if AppUpdate.table_exists?
        @updates = AppUpdate.order(created_at: :desc).limit(50).to_a
        
        # In production, also sync with R2 to ensure consistency
        if Rails.env.production?
          sync_updates_with_r2
        end
        
        @stats = {
          total: AppUpdate.count,
          published: AppUpdate.where(published: true).count,
          draft: AppUpdate.where(published: false).count,
          total_downloads: AppUpdate.sum(:download_count) || 0
        }
      end
      
      respond_to do |format|
        format.html # renders app/views/admin/updates/index.html.erb  
        format.json { render json: { updates: @updates, stats: @stats } }
      end
      
    rescue => e
      Rails.logger.error "Admin index error: #{e.message}"
      
      # Always provide safe fallbacks
      @updates = []
      @stats = { total: 0, published: 0, draft: 0, total_downloads: 0 }
      
      respond_to do |format|
        format.html # Still try to render the view with empty data
        format.json { render json: { error: e.message }, status: 500 }
      end
    end
  end

  # GET /admin/updates/1
  def show
    @download_stats = @update.download_count
    @created_days_ago = (Date.current - @update.created_at.to_date).to_i
  end

  # GET /admin/updates/new
  def new
    @update = AppUpdate.new
    @update.runtime_version = "1.0.0"
  end

  # GET /admin/updates/1/edit
  def edit
  end

  # POST /admin/updates
  def create
    @update = AppUpdate.new(update_params)
    @update.user = current_user if @update.respond_to?(:user=)

    if params[:apk].present?
      begin
        apk_result = upload_apk(params[:apk])
        @update.apk_url = apk_result[:url]
        @update.apk_key = apk_result[:key]
        @update.apk_size = apk_result[:size]
        @update.apk_filename = apk_result[:filename]
      rescue => e
        Rails.logger.error "APK upload failed: #{e.message}"
        flash[:error] = "APK upload failed: #{e.message}"
        render :new and return
      end
    end

    if @update.save
      flash[:success] = 'Update created successfully.'
      redirect_to admin_update_path(@update)
    else
      flash[:error] = 'Failed to create update.'
      render :new
    end
  end

  # PATCH/PUT /admin/updates/1
  def update
    if params[:apk].present?
      begin
        # Clean up old APK if replacing
        cleanup_apk(@update.apk_key, @update.version) if @update.apk_key.present?
        
        apk_result = upload_apk(params[:apk])
        @update.apk_url = apk_result[:url]
        @update.apk_key = apk_result[:key]
        @update.apk_size = apk_result[:size]
        @update.apk_filename = apk_result[:filename]
      rescue => e
        Rails.logger.error "APK upload failed: #{e.message}"
        flash[:error] = "APK upload failed: #{e.message}"
        render :edit and return
      end
    end

    if @update.update(update_params)
      flash[:success] = 'Update was successfully updated.'
      redirect_to admin_update_path(@update)
    else
      flash[:error] = 'Failed to update.'
      render :edit
    end
  end

  # DELETE /admin/updates/1
  def destroy
    if @update.published?
      flash[:error] = 'Cannot delete published updates. Unpublish first.'
      redirect_to admin_updates_path and return
    end

    cleanup_apk(@update.apk_key, @update.version) if @update.apk_key.present?
    
    @update.destroy
    flash[:success] = 'Update was successfully deleted.'
    redirect_to admin_updates_path
  end

  # PATCH /admin/updates/1/publish
  def publish
    if @update.apk_url.blank?
      render json: { error: 'Cannot publish update without an APK file.' }, status: :unprocessable_entity
      return
    end

    @update.update!(
      published: true,
      published_at: Time.current
    )
    
    render json: { success: true, message: 'Update published successfully!' }
  end

  # PATCH /admin/updates/1/unpublish
  def unpublish
    @update.update!(
      published: false,
      published_at: nil
    )
    
    render json: { success: true, message: 'Update unpublished successfully.' }
  end

  # POST /admin/updates/upload_apk_only
  def upload_apk_only
    render json: {
      status: 'success',
      message: 'APK uploaded successfully'
    }
  end

  # GET /admin/updates/stats
  def stats
    render json: {
      status: 'success',
      message: 'Update statistics',
      data: @stats || {
        total_updates: AppUpdate.count,
        published_updates: AppUpdate.where(published: true).count,
        draft_updates: AppUpdate.where(published: false).count
      }
    }
  end

  private

  def set_update
    @update = AppUpdate.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    flash[:error] = 'Update not found.'
    redirect_to admin_updates_path
  end

  def update_params
    params.require(:app_update).permit(
      :version, :runtime_version, :description, :force_update, :published,
      changelog: []
    )
  end

  def upload_apk(file)
    # Validate APK file type
    unless file.content_type == 'application/vnd.android.package-archive' || 
           file.original_filename.end_with?('.apk')
      raise "Invalid file type. Only APK files (.apk) are allowed."
    end

    # Increase size limit to 200MB for APK files
    max_size = 200.megabytes
    if file.size > max_size
      raise "File too large. Maximum size is #{max_size / 1.megabyte}MB."
    end

    key = SecureRandom.uuid
    version = params.dig(:app_update, :version) || '1.0.0'
    
    if Rails.env.production?
      upload_apk_to_r2(file, key, version)
    else
      upload_apk_to_local(file, key, version)
    end
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
    filename = file.original_filename
    object_key = "AppUpdate/#{version}/#{filename}"
    
    # Upload to R2
    client.put_object(
      bucket: bucket_name,
      key: object_key,
      body: file.read,
      content_type: 'application/vnd.android.package-archive',
      metadata: {
        'version' => version,
        'upload_key' => key,
        'original_filename' => filename,
        'uploaded_at' => Time.current.iso8601
      }
    )
    
    public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 'https://pub-63612670c2d64075820ce8724feff8ea.r2.dev'
    url = "#{public_base}/#{object_key}"
    
    Rails.logger.info "APK uploaded to R2: #{object_key} (#{file.size} bytes)"
    
    {
      key: key,
      url: url,
      size: file.size,
      filename: filename,
      original_filename: file.original_filename
    }
  end

  def upload_apk_to_local(file, key, version)
    filename = file.original_filename
    upload_path = Rails.root.join('public', 'uploads', 'apks', version)
    FileUtils.mkdir_p(upload_path)
    
    file_path = upload_path.join(filename)
    File.open(file_path, 'wb') do |f|
      f.write(file.read)
    end
    
    base_url = Rails.env.production? ? ENV['APP_DOMAIN'] : request.base_url
    url = "#{base_url}/uploads/apks/#{version}/#{filename}"
    
    unless File.exist?(file_path) && File.size(file_path) > 0
      raise "File upload verification failed"
    end
    
    Rails.logger.info "APK uploaded locally: #{filename} (#{file.size} bytes)"
    
    {
      key: key,
      url: url,
      size: file.size,
      filename: filename,
      original_filename: file.original_filename
    }
  end

  def cleanup_apk(apk_key, version)
    return unless apk_key.present? && version.present?
    
    if Rails.env.production?
      cleanup_apk_from_r2(apk_key, version)
    else
      cleanup_apk_from_local(apk_key, version)
    end
  end

  def cleanup_apk_from_r2(apk_key, version)
    require 'aws-sdk-s3'
    
    client = Aws::S3::Client.new(
      access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
      secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
      region: 'auto',
      endpoint: ENV['CLOUDFLARE_R2_ENDPOINT'] || 'https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com',
      force_path_style: true
    )

    bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
    
    # List objects in the version folder to find the APK file
    response = client.list_objects_v2(
      bucket: bucket_name,
      prefix: "AppUpdate/#{version}/"
    )
    
    response.contents.each do |object|
      if object.key.end_with?('.apk')
        client.delete_object(bucket: bucket_name, key: object.key)
        Rails.logger.info "APK cleaned up from R2: #{object.key}"
      end
    end
  rescue => e
    Rails.logger.error "Failed to cleanup APK from R2: #{e.message}"
  end

  def cleanup_apk_from_local(apk_key, version)
    version_path = Rails.root.join('public', 'uploads', 'apks', version)
    
    if Dir.exist?(version_path)
      Dir.glob(File.join(version_path, '*.apk')).each do |apk_file|
        File.delete(apk_file)
        Rails.logger.info "APK cleaned up locally: #{File.basename(apk_file)}"
      end
    end
  rescue => e
    Rails.logger.error "Failed to cleanup local APK file: #{e.message}"
  end

  def sync_updates_with_r2
    # Sync database with R2 to ensure consistency
    begin
      require 'aws-sdk-s3'
      
      client = Aws::S3::Client.new(
        access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
        secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
        region: 'auto',
        endpoint: ENV['CLOUDFLARE_R2_ENDPOINT'] || 'https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com',
        force_path_style: true
      )

      bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
      
      # List all AppUpdate folders in R2
      response = client.list_objects_v2(
        bucket: bucket_name,
        prefix: 'AppUpdate/',
        delimiter: '/'
      )
      
      # Log R2 contents for debugging
      Rails.logger.info "R2 AppUpdate folders found: #{response.common_prefixes.map(&:prefix)}"
      
    rescue => e
      Rails.logger.error "Failed to sync with R2: #{e.message}"
    end
  end
end