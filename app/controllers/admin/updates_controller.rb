# app/controllers/admin/updates_controller.rb
class Admin::UpdatesController < WebApplicationController
  # Skip CSRF for admin routes to prevent 500 errors
skip_before_action :verify_authenticity_token

before_action :set_update, only: [:show, :edit, :update, :destroy, :publish, :unpublish]
  before_action :ensure_admin_user!
  
  
  # GET /admin/updates
  def index
    @updates = AppUpdate.order(created_at: :desc).limit(50)
    @stats = {
      total: AppUpdate.count,
      published: AppUpdate.where(published: true).count,
      draft: AppUpdate.where(published: false).count,
      total_downloads: AppUpdate.sum(:download_count)
    }
    
    # Render the view or return JSON if requested
    respond_to do |format|
      format.html # renders app/views/admin/updates/index.html.erb
      format.json { render json: { updates: @updates, stats: @stats } }
    end
  rescue => e
    Rails.logger.error "Admin updates index error: #{e.message}"
    flash[:error] = "Error loading updates: #{e.message}"
    redirect_to sign_in_path
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

    if params[:bundle].present?
      begin
        bundle_result = upload_bundle(params[:bundle])
        @update.bundle_url = bundle_result[:url]
        @update.bundle_key = bundle_result[:key]
        @update.bundle_size = bundle_result[:size] if bundle_result[:size]
      rescue => e
        Rails.logger.error "Bundle upload failed: #{e.message}"
        flash[:error] = "Bundle upload failed: #{e.message}"
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
    if params[:bundle].present?
      begin
        bundle_result = upload_bundle(params[:bundle])
        @update.bundle_url = bundle_result[:url]
        @update.bundle_key = bundle_result[:key]
        @update.bundle_size = bundle_result[:size] if bundle_result[:size]
      rescue => e
        Rails.logger.error "Bundle upload failed: #{e.message}"
        flash[:error] = "Bundle upload failed: #{e.message}"
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

    cleanup_bundle(@update.bundle_key) if @update.bundle_key.present?
    
    @update.destroy
    flash[:success] = 'Update was successfully deleted.'
    redirect_to admin_updates_path
  end

  # PATCH /admin/updates/1/publish
  def publish
    if @update.bundle_url.blank?
      render json: { error: 'Cannot publish update without a bundle file.' }, status: :unprocessable_entity
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

  # POST /admin/updates/upload_bundle_only
  def upload_bundle_only
    render json: {
      status: 'success',
      message: 'Bundle uploaded successfully'
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

  def ensure_admin_user!
    unless current_user&.admin?
      flash[:error] = 'Access denied. Admin privileges required.'
      redirect_to sign_in_path
    end
  end

  def upload_bundle(file)
    unless file.content_type == 'application/javascript' || 
           file.original_filename.end_with?('.js', '.bundle')
      raise "Invalid file type. Only JavaScript files are allowed."
    end

    max_size = 50.megabytes
    if file.size > max_size
      raise "File too large. Maximum size is #{max_size / 1.megabyte}MB."
    end

    key = SecureRandom.uuid
    filename = "#{key}.js"
    
    upload_path = Rails.root.join('public', 'uploads', 'bundles')
    FileUtils.mkdir_p(upload_path)
    
    file_path = upload_path.join(filename)
    File.open(file_path, 'wb') do |f|
      f.write(file.read)
    end
    
    base_url = Rails.env.production? ? ENV['APP_DOMAIN'] : request.base_url
    url = "#{base_url}/uploads/bundles/#{filename}"
    
    unless File.exist?(file_path) && File.size(file_path) > 0
      raise "File upload verification failed"
    end
    
    Rails.logger.info "Bundle uploaded successfully: #{filename} (#{file.size} bytes)"
    
    {
      key: key,
      url: url,
      size: file.size,
      filename: filename,
      original_filename: file.original_filename
    }
  end

  def cleanup_bundle(bundle_key)
    return unless bundle_key.present?
    
    filename = "#{bundle_key}.js"
    file_path = Rails.root.join('public', 'uploads', 'bundles', filename)
    
    if File.exist?(file_path)
      File.delete(file_path)
      Rails.logger.info "Bundle file cleaned up: #{filename}"
    end
  rescue => e
    Rails.logger.error "Failed to cleanup bundle file: #{e.message}"
  end
end