# app/serializers/user_serializer.rb
class UserSerializer < ActiveModel::Serializer
  include Rails.application.routes.url_helpers

  attributes :id, :email, :roles, :avatar_url

  def roles
    object.roles.pluck(:name)
  end

  def avatar_url
    return unless object.avatar.attached?
    rails_blob_url(object.avatar, host: "http://192.168.100.39:3000") # <- Add host here
  end
end