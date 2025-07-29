class Api::V1::TypingStatusController < ApplicationController
  before_action :authenticate_user!

  def create
    receiver = User.find_by(id: params[:receiver_id])
    return head :not_found unless receiver

    # Broadcast typing signal
    ActionCable.server.broadcast(
      "chat_#{receiver.id}",
      {
        type: "typing",
        from: current_user.id,
        username: current_user.username
      }
    )

    head :ok
  end
end