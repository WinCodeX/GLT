# app/channels/user_notifications_channel.rb
class UserNotificationsChannel < ApplicationCable::Channel
  def subscribed
    stream_from "user_notifications_#{current_user.id}"
    Rails.logger.info "User #{current_user.id} subscribed to notification updates"
  end
  
  def unsubscribed
    Rails.logger.info "User #{current_user.id} unsubscribed from notification updates"
  end
end