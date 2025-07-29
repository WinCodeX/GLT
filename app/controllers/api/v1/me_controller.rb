module Api
  module V1
    class MeController < ApplicationController
      before_action :authenticate_user!

      include Rails.application.routes.url_helpers

def show
  render json: UserSerializer.new(current_user).serializable_hash
end

      def update_avatar
  current_user.avatar.attach(params[:avatar])

  if current_user.avatar.attached?
    render json: {
      message: 'Avatar updated successfully',
      avatar_url: rails_blob_url(current_user.avatar, only_path: true)
    }, status: :ok
  else
    render json: { error: 'Avatar failed to upload' }, status: :unprocessable_entity
  end
end
    end
  end
end