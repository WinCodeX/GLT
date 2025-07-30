class UserSerializer < ActiveModel::Serializer
  include Rails.application.routes.url_helpers

  attributes :id, :email, :roles, :avatar_url

  def roles
    object.roles.pluck(:name)
  end

  def avatar_url
  return unless object.avatar.attached?

  host = Rails.configuration.x.avatar_hosts&.find(&:present?)
  return unless host

  rails_blob_url(object.avatar, host: host)
end
end