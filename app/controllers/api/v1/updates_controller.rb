# app/controllers/api/v1/updates_controller.rb

class Api::V1::UpdatesController < ApplicationController
  before_action :authenticate_user!, except: [:manifest, :info]

  def manifest
    # Expo Updates manifest endpoint
    latest_update = AppUpdate.published.latest
    
    if latest_update
      render json: {
        id: latest_update.update_id,
        createdAt: latest_update.created_at.iso8601,
        runtimeVersion: latest_update.runtime_version,
        launchAsset: {
          key: latest_update.bundle_key,
          contentType: 'application/javascript',
          url: latest_update.bundle_url
        },
        assets: latest_update.assets || [],
        metadata: {
          version: latest_update.version,
          changelog: latest_update.changelog
        }
      }
    else
      render json: { error: 'No updates available' }, status: 404
    end
  end

  def info
    # Get latest update information
    latest_update = AppUpdate.published.latest
    current_version = params[:current_version] || '1.0.0'
    
    if latest_update && version_greater_than?(latest_update.version, current_version)
      render json: {
        available: true,
        version: latest_update.version,
        changelog: latest_update.changelog,
        release_date: latest_update.created_at.iso8601,
        force_update: latest_update.force_update,
        download_url: latest_update.bundle_url
      }
    else
      render json: {
        available: false,
        current_version: current_version
      }
    end
  end

  def check
    # Check if updates are available for specific version
    current_version = params[:version] || '1.0.0'
    latest_update = AppUpdate.published.latest
    
    has_update = latest_update && version_greater_than?(latest_update.version, current_version)
    
    render json: {
      has_update: has_update,
      latest_version: latest_update&.version,
      current_version: current_version,
      force_update: has_update ? latest_update.force_update : false
    }
  end

  def create
    # Admin endpoint to create new update
    return render json: { error: 'Unauthorized' }, status: 401 unless current_user.admin?
    
    @update = AppUpdate.new(update_params)
    @update.update_id = SecureRandom.uuid
    
    if @update.save
      render json: @update, status: :created
    else
      render json: { errors: @update.errors }, status: :unprocessable_entity
    end
  end

  def publish
    # Admin endpoint to publish an update
    return render json: { error: 'Unauthorized' }, status: 401 unless current_user.admin?
    
    @update = AppUpdate.find(params[:id])
    @update.update(published: true, published_at: Time.current)
    
    render json: @update
  end

  def upload_bundle
    # Admin endpoint to upload update bundle
    return render json: { error: 'Unauthorized' }, status: 401 unless current_user.admin?
    
    bundle_file = params[:bundle]
    return render json: { error: 'No bundle file provided' }, status: 400 unless bundle_file
    
    # Store the bundle file (implement your storage logic)
    bundle_key = SecureRandom.uuid
    bundle_url = upload_to_storage(bundle_file, bundle_key)
    
    render json: {
      bundle_key: bundle_key,
      bundle_url: bundle_url,
      size: bundle_file.size
    }
  end

  private

  def update_params
    params.require(:update).permit(:version, :runtime_version, :bundle_url, :bundle_key, :force_update, changelog: [])
  end

  def version_greater_than?(version1, version2)
    Gem::Version.new(version1) > Gem::Version.new(version2)
  rescue ArgumentError
    false
  end

  def upload_to_storage(file, key)
    # Implement your file storage logic here
    # This could be AWS S3, Google Cloud Storage, or local storage
    # For now, returning a placeholder URL
    "#{request.base_url}/uploads/bundles/#{key}.js"
  end
end