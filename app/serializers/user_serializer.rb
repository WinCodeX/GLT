# app/serializers/user_serializer.rb
class UserSerializer < ActiveModel::Serializer
  include Rails.application.routes.url_helpers

  attributes :id, :email, :roles, :avatar_url

  def roles
    object.roles.pluck(:name)
  end

  def avatar_url
    rails_blob_url(object.avatar, only_path: true) if object.avatar.attached?
  end
end