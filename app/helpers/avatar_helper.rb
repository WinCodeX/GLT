# app/helpers/avatar_helper.rb
module AvatarHelper
  # Include UrlHostHelper for fallback host resolution if needed
  include UrlHostHelper
  
  def avatar_url(user, variant: :thumb)
    return nil unless user&.avatar&.attached?
    
    begin
      if Rails.env.production?
        # Production: Use Cloudflare R2 public URLs
        generate_r2_public_url(user.avatar, variant)
      else
        # Development: Use Rails URLs via UrlHostHelper
        base_host = first_available_host # From UrlHostHelper
        avatar_path = rails_blob_path(user.avatar.variant(resize_to_limit: variant_size(variant)))
        "#{base_host}#{avatar_path}"
      end
    rescue => e
      Rails.logger.error "Avatar URL generation failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      fallback_avatar_url(variant)
    end
  end
  
  # Generate direct avatar URL for API responses
  def avatar_api_url(user, variant: :thumb)
    url = avatar_url(user, variant: variant)
    return nil unless url
    
    # Return the complete URL (already includes domain)
    url
  end
  
  # Fallback avatar when user has no avatar or generation fails
  def fallback_avatar_url(variant = :thumb)
    size = variant_size(variant)[0] # Get width
    "https://ui-avatars.com/api/?name=User&size=#{size}&background=6366f1&color=ffffff"
  end
  
  private
  
  def generate_r2_public_url(avatar, variant)
    # Get the public R2 URL base
    public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL'] || 
                  raise("CLOUDFLARE_R2_PUBLIC_URL not configured for production")
    
    # Generate variant and get its key
    variant_blob = avatar.variant(resize_to_limit: variant_size(variant))
    
    # For Active Storage with R2, we need to construct the URL properly
    if variant_blob.respond_to?(:key)
      key = variant_blob.key
    else
      # Fallback: try to get the key from the original blob
      key = avatar.blob.key
    end
    
    "#{public_base}/#{key}"
  end
  
  def variant_size(variant)
    case variant.to_sym
    when :thumb then [150, 150]
    when :small then [100, 100]
    when :medium then [300, 300]
    when :large then [600, 600]
    when :xl then [1200, 1200]
    else [150, 150]
    end
  end
end