# app/models/business.rb - Updated with logo support
class Business < ApplicationRecord
  belongs_to :owner, class_name: 'User', foreign_key: 'user_id'
  has_many :user_businesses, dependent: :destroy
  has_many :users, through: :user_businesses
  has_and_belongs_to_many :categories, join_table: 'business_categories'

  validates :name, presence: true, length: { minimum: 2, maximum: 100 }
  validates :phone_number, presence: true, format: { 
    with: /\A\+?[\d\s\-\(\)]+\z/, 
    message: "must be a valid phone number" 
  }
  validates :owner, presence: true
  validate :must_have_at_least_one_category

  # Logo URL generation
  def logo_url
    return nil unless owner_id.present? && id.present?
    
    if Rails.env.production?
      # Production: Check R2 for business logo
      generate_r2_business_logo_url
    else
      # Development: Check local storage
      generate_local_business_logo_url
    end
  end

  private

  def must_have_at_least_one_category
    if categories.empty?
      errors.add(:categories, "must have at least one category")
    end
  end

  def generate_r2_business_logo_url
    return nil unless r2_business_logo_exists?
    
    public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 'https://pub-63612670c2d64075820ce8724feff8ea.r2.dev'
    
    # Try common image extensions
    %w[.jpg .jpeg .png .gif .webp].each do |extension|
      logo_key = "businesslogo/#{owner_id}/#{id}/logo#{extension}"
      if r2_object_exists?(logo_key)
        return "#{public_base}/#{logo_key}"
      end
    end
    
    nil
  end

  def generate_local_business_logo_url
    base_path = Rails.root.join('public', 'uploads', 'businesslogo', owner_id.to_s, id.to_s)
    return nil unless Dir.exist?(base_path)
    
    %w[.jpg .jpeg .png .gif .webp].each do |extension|
      logo_path = base_path.join("logo#{extension}")
      if File.exist?(logo_path)
        return "/uploads/businesslogo/#{owner_id}/#{id}/logo#{extension}"
      end
    end
    
    nil
  end

  def r2_business_logo_exists?
    require 'aws-sdk-s3'
    
    client = Aws::S3::Client.new(
      access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
      secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
      region: 'auto',
      endpoint: ENV['CLOUDFLARE_R2_ENDPOINT'] || 'https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com',
      force_path_style: true
    )

    bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
    logo_prefix = "businesslogo/#{owner_id}/#{id}/"
    
    response = client.list_objects_v2(
      bucket: bucket_name,
      prefix: logo_prefix,
      max_keys: 1
    )
    
    response.contents.any?
  rescue => e
    Rails.logger.error "Error checking R2 business logo existence: #{e.message}"
    false
  end

  def r2_object_exists?(key)
    require 'aws-sdk-s3'
    
    client = Aws::S3::Client.new(
      access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
      secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
      region: 'auto',
      endpoint: ENV['CLOUDFLARE_R2_ENDPOINT'] || 'https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com',
      force_path_style: true
    )

    bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
    
    client.head_object(bucket: bucket_name, key: key)
    true
  rescue Aws::S3::Errors::NotFound
    false
  rescue => e
    Rails.logger.error "Error checking R2 object existence: #{e.message}"
    false
  end
end