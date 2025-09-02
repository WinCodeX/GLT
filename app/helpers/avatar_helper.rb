module AvatarHelper
  include UrlHostHelper
  
  def avatar_url(user, variant: :thumb)
    return nil unless user&.avatar&.attached?
    
    begin
      if Rails.env.production?
        # Production: Use Active Storage URLs (now that we're using cloudflare service)
        generate_production_avatar_url(user.avatar, variant)
      else
        # Development: Use Rails URLs via UrlHostHelper
        base_host = first_available_host
        avatar_path = rails_blob_path(user.avatar.variant(resize_to_limit: variant_size(variant)))
        "#{base_host}#{avatar_path}"
      end
    rescue => e
      Rails.logger.error "Avatar URL generation failed for user #{user.id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      fallback_avatar_url(variant)
    end
  end
  
  # Generate direct avatar URL for API responses
  def avatar_api_url(user, variant: :thumb)
    url = avatar_url(user, variant: variant)
    return fallback_avatar_url(variant) unless url
    url
  end
  
  # Fallback avatar when user has no avatar or generation fails
  def fallback_avatar_url(variant = :thumb)
    size = variant_size(variant)[0]
    "https://ui-avatars.com/api/?name=User&size=#{size}&background=6366f1&color=ffffff"
  end
  
  private
  
  def generate_production_avatar_url(avatar, variant)
    # Use direct R2 URLs instead of Rails Active Storage redirect URLs
    construct_direct_r2_url(avatar, variant)
  end
  
  def construct_direct_r2_url(avatar, variant)
    # Construct direct R2 URL in the format: {R2_PUBLIC_URL}/avatars/{blob_key}/{filename}
    public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 'https://pub-63612670c2d64075820ce8724feff8ea.r2.dev'
    return fallback_avatar_url(variant) unless public_base
    
    # Use the blob key and filename to match your R2 structure
    blob_key = avatar.blob.key
    filename = avatar.blob.filename || 'avatar.jpg'
    
    "#{public_base}/avatars/#{blob_key}/#{filename}"
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