class UserSerializer < ActiveModel::Serializer
  include UrlHostHelper

  attributes :id, :email, :roles, :avatar_url

  def roles
    object.roles.pluck(:name)
  end

  def avatar_url
    return unless object.avatar.attached?
    fallback_host_url_for(object.avatar)
  end
end