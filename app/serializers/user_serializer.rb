class UserSerializer < ActiveModel::Serializer
  include Rails.application.routes.url_helpers
  include UrlHostHelper

  attributes :id, :email, :roles, :avatar_url

  def roles
    object.roles.pluck(:name)
  end

  def avatar_url
    return unless object.avatar.attached?

    host = first_available_host
    return unless host

    rails_blob_url(object.avatar, host: host)
  end
end