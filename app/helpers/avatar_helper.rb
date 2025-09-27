
# app/helpers/avatar_helper.rb - Fixed for R2 user folders
module AvatarHelper
  include UrlHostHelper
  
  def avatar_url(user, variant: :thumb)
    return nil unless user&.present?
    
    begin
      if Rails.env.production?
        # Production: Check R2 for user's avatar
        generate_r2_user_avatar_url(user)
      else
        # Development: Use Active Storage as before
        return nil unless user.avatar&.attached?
        base_host = first_available_host
        avatar_path = rails_blob_path(user.avatar.variant(resize_to_limit: variant_size(variant)))
        "#{base_host}#{avatar_path}"
      end
    rescue => e
      Rails.logger.error "Avatar URL generation failed for user #{user.id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      nil
    end
  end
  
  # Generate direct avatar URL for API responses
  def avatar_api_url(user, variant: :thumb)
    avatar_url(user, variant: variant)
  end
  
  # Fallback avatar when user has no avatar or generation fails
  def fallback_avatar_url(variant = :thumb)
    size = variant_size(variant)[0]
    "https://ui-avatars.com/api/?name=User&size=#{size}&background=6366f1&color=ffffff"
  end
  
  private
  
  def generate_r2_user_avatar_url(user)
    # Check if avatar exists in R2 user folder
    return nil unless r2_avatar_exists?(user)
    
    # Generate URL based on user folder structure
    public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 'https://pub-63612670c2d64075820ce8724feff8ea.r2.dev'
    
    # Try common image extensions
    %w[.jpg .jpeg .png .gif .webp].each do |extension|
      avatar_key = "avatars/#{user.id}/avatar#{extension}"
      if r2_object_exists?(avatar_key)
        return "#{public_base}/#{avatar_key}"
      end
    end
    
    nil
  end
  
  def r2_avatar_exists?(user)
    # Quick check if user has avatar folder in R2
    require 'aws-sdk-s3'
    
    client = Aws::S3::Client.new(
      access_key_id: ENV['CLOUDFLARE_R2_ACCESS_KEY_ID'],
      secret_access_key: ENV['CLOUDFLARE_R2_SECRET_ACCESS_KEY'],
      region: 'auto',
      endpoint: ENV['CLOUDFLARE_R2_ENDPOINT'] || 'https://92fd9199e9a7d60761d017e2a687e647.r2.cloudflarestorage.com',
      force_path_style: true
    )

    bucket_name = ENV['CLOUDFLARE_R2_BUCKET'] || 'gltapp'
    user_prefix = "avatars/#{user.id}/"
    
    response = client.list_objects_v2(
      bucket: bucket_name,
      prefix: user_prefix,
      max_keys: 1
    )
    
    response.contents.any?
  rescue => e
    Rails.logger.error "❌ Error checking R2 avatar existence: #{e.message}"
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
    Rails.logger.error "❌ Error checking R2 object existence: #{e.message}"
    false
  end
  
  def variant_size(variant)
    case variant.to_sym
    when :thumb then [150, 150]
    when :small then [100, 100]
    when :medium then [300, 300]
    when :large then [600, 600]
    when :xl then [1200, 1200]
    when :original then nil
    else [150, 150]
    end
  end
end