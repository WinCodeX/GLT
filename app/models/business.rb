# app/models/business.rb - Fixed with proper associations and logo support
class Business < ApplicationRecord
  belongs_to :owner, class_name: "User"
  has_many :user_businesses, dependent: :destroy
  has_many :users, through: :user_businesses
  has_many :business_invites, dependent: :destroy
  has_many :business_categories, dependent: :destroy
  has_many :categories, through: :business_categories
  
  # Validations
  validates :name, presence: true, length: { minimum: 2, maximum: 100 }
  validates :phone_number, presence: true, format: { 
    with: /\A[\+]?[0-9\-\(\)\s]+\z/, 
    message: "Please enter a valid phone number" 
  }
  validate :categories_limit
  validate :categories_presence

  # Scopes
  scope :with_category, ->(category_slug) { 
    joins(:categories).where(categories: { slug: category_slug }) 
  }
  scope :with_categories, ->(category_slugs) { 
    joins(:categories).where(categories: { slug: category_slugs }).distinct
  }

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

  # Instance methods
  def category_names
    categories.active.pluck(:name)
  end

  def category_slugs
    categories.active.pluck(:slug)
  end

  def primary_category
    categories.active.first
  end

  def add_categories(category_ids)
    return false if category_ids.blank?
    
    # Limit to 5 categories max
    limited_ids = category_ids.first(5)
    new_categories = Category.active.where(id: limited_ids)
    
    # Add only new categories (avoid duplicates)
    new_categories.each do |category|
      unless categories.include?(category)
        categories << category
      end
    end
    
    valid?
  end

  def remove_category(category_id)
    category = categories.find_by(id: category_id)
    return false unless category
    
    categories.delete(category)
    valid?
  end

  private

  def categories_limit
    if categories.length > 5
      errors.add(:categories, "cannot exceed 5 categories")
    end
  end

  def categories_presence
    if categories.length == 0
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