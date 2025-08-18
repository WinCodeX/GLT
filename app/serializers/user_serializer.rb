# app/serializers/user_serializer.rb - FIXED: Safe avatar URL generation
class UserSerializer < ActiveModel::Serializer
  include Rails.application.routes.url_helpers
  include UrlHostHelper

  attributes :id, :email, :first_name, :last_name, :display_name, :username, :phone, :roles, :avatar_url

  def roles
    begin
      object.roles.pluck(:name)
    rescue => e
      Rails.logger.error "Error fetching user roles: #{e.message}"
      []
    end
  end

  def avatar_url
    return nil unless object.avatar.attached?

    # Check if the avatar blob exists and is persisted
    begin
      avatar_blob = object.avatar.blob
      return nil unless avatar_blob&.persisted?
      
      # Additional safety check - ensure the attachment is properly linked
      return nil unless object.avatar.attachment&.persisted?
      
      host = first_available_host
      return nil unless host

      # Generate URL with error handling
      rails_blob_url(object.avatar, host: host, protocol: host.include?('https') ? 'https' : 'http')
      
    rescue ActiveStorage::FileNotFoundError => e
      Rails.logger.warn "Avatar file not found for user #{object.id}: #{e.message}"
      nil
    rescue NoMethodError => e
      Rails.logger.warn "Avatar method error for user #{object.id}: #{e.message}"
      nil
    rescue => e
      Rails.logger.error "Error generating avatar URL for user #{object.id}: #{e.message}"
      nil
    end
  end

  # Helper methods for backward compatibility
  def first_name
    object.respond_to?(:first_name) ? object.first_name : nil
  end

  def last_name
    object.respond_to?(:last_name) ? object.last_name : nil
  end

  def display_name
    object.respond_to?(:display_name) ? object.display_name : nil
  end

  def username
    object.respond_to?(:username) ? object.username : nil
  end

  def phone
    object.respond_to?(:phone) ? object.phone : nil
  end
end