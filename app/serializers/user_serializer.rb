class UserSerializer < ActiveModel::Serializer
  include Rails.application.routes.url_helpers
  include ActionController::MimeResponds

  attributes :id, :email, :roles, :avatar_url

  def roles
    object.roles.pluck(:name)
  end

  def avatar_url
    return unless object.avatar.attached?

    available_host = first_available_host
    return unless available_host

    rails_blob_url(object.avatar, host: available_host)
  end

  private

  def first_available_host
    Rails.configuration.x.avatar_hosts.each do |host|
      begin
        # Ping only the root of the domain to test availability
        uri = URI.parse(host)
        response = Net::HTTP.get_response(uri)
        return host if response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
      rescue StandardError
        next
      end
    end
    nil
  end
end