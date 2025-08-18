class UserSerializer < ActiveModel::Serializer
  include Rails.application.routes.url_helpers
  include UrlHostHelper

  attributes :id, :email, :roles, :avatar_url

  def roles
    object.roles.pluck(:name)
  end

  def avatar_url
    return nil unless object.avatar.attached?

    host = first_available_host
    return nil unless host

    begin
      rails_blob_url(object.avatar, host: host)
    rescue => e
      Rails.logger.error "Error generating avatar URL: #{e.message}"
      nil
    end
  end
end