# app/models/app_update.rb
class AppUpdate < ApplicationRecord
  validates :version, presence: true, uniqueness: true
  validates :update_id, presence: true, uniqueness: true
  validates :apk_url, presence: true, if: :published?

  scope :published, -> { where(published: true) }
  scope :latest_first, -> { order(created_at: :desc) }

  before_validation :generate_update_id, on: :create
  before_save :set_apk_size_if_missing

  def self.latest
    latest_first.first
  end

  def version_number
    Gem::Version.new(version)
  rescue ArgumentError
    Gem::Version.new('0.0.0')
  end

  def self.current_version
    published.latest&.version || '1.0.0'
  end

  def self.has_newer_version?(current_version)
    latest_update = published.latest
    return false unless latest_update
    
    begin
      Gem::Version.new(latest_update.version) > Gem::Version.new(current_version)
    rescue ArgumentError
      false
    end
  end

  def increment_download_count!
    increment!(:download_count)
  end

  def published?
    read_attribute(:published) == true
  end

  def apk_file_size_mb
    return 0 unless apk_size
    (apk_size.to_f / 1.megabyte).round(2)
  end

  def apk_available?
    apk_url.present? && (Rails.env.production? ? r2_apk_exists? : local_apk_exists?)
  end

  def download_url
    if Rails.env.production?
      apk_url
    else
      # For development, ensure URL is accessible
      apk_url
    end
  end

  def apk_filename_from_url
    return apk_filename if apk_filename.present?
    return nil unless apk_url.present?
    
    uri = URI.parse(apk_url)
    File.basename(uri.path)
  rescue URI::InvalidURIError
    nil
  end

  private

  def generate_update_id
    self.update_id ||= SecureRandom.uuid
  end

  def set_apk_size_if_missing
    if apk_url.present? && apk_size.blank?
      self.apk_size = fetch_apk_size_from_storage
    end
  end

  def fetch_apk_size_from_storage
    if Rails.env.production?
      fetch_apk_size_from_r2
    else
      fetch_apk_size_from_local
    end
  end

  def fetch_apk_size_from_r2
    return 0 unless apk_url.present?
    
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
      object_key = "AppUpdate/#{version}/#{apk_filename_from_url}"
      
      response = client.head_object(bucket: bucket_name, key: object_key)
      response.content_length
    rescue => e
      Rails.logger.error "Failed to fetch APK size from R2: #{e.message}"
      0
    end
  end

  def fetch_apk_size_from_local
    return 0 unless apk_url.present?
    
    begin
      # Extract filename from URL and construct local path
      filename = apk_filename_from_url
      return 0 unless filename
      
      file_path = Rails.root.join('public', 'uploads', 'apks', version, filename)
      
      if File.exist?(file_path)
        File.size(file_path)
      else
        0
      end
    rescue => e
      Rails.logger.error "Failed to fetch APK size from local storage: #{e.message}"
      0
    end
  end

  def r2_apk_exists?
    return false unless apk_url.present?
    
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
      object_key = "AppUpdate/#{version}/#{apk_filename_from_url}"
      
      client.head_object(bucket: bucket_name, key: object_key)
      true
    rescue Aws::S3::Errors::NotFound
      false
    rescue => e
      Rails.logger.error "Error checking R2 APK existence: #{e.message}"
      false
    end
  end

  def local_apk_exists?
    return false unless apk_url.present?
    
    filename = apk_filename_from_url
    return false unless filename
    
    file_path = Rails.root.join('public', 'uploads', 'apks', version, filename)
    File.exist?(file_path)
  end
end