# app/helpers/avatar_helper.rb
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
    return nil unless url
    url
  end
  
  # Fallback avatar when user has no avatar or generation fails
  def fallback_avatar_url(variant = :thumb)
    size = variant_size(variant)[0]
    "https://ui-avatars.com/api/?name=User&size=#{size}&background=6366f1&color=ffffff"
  end
  
  private
  
  def generate_production_avatar_url(avatar, variant)
    # Now that we use cloudflare service, let Active Storage handle URL generation
    begin
      if variant == :original
        # For original size, use the avatar directly
        rails_blob_url(avatar, host: Rails.application.routes.default_url_options[:host])
      else
        # For variants, create the variant and get its URL
        variant_blob = avatar.variant(resize_to_limit: variant_size(variant))
        rails_blob_url(variant_blob, host: Rails.application.routes.default_url_options[:host])
      end
    rescue => e
      Rails.logger.error "Active Storage URL generation failed: #{e.message}"
      # If Active Storage URL fails, try direct R2 construction as fallback
      construct_direct_r2_url(avatar, variant)
    end
  end
  
  def construct_direct_r2_url(avatar, variant)
    # Fallback method if Active Storage URL generation fails
    public_base = ENV['CLOUDFLARE_R2_PUBLIC_URL']
    return fallback_avatar_url(variant) unless public_base
    
    # Use the blob key directly
    blob_key = avatar.blob.key
    "#{public_base}/#{blob_key}"
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