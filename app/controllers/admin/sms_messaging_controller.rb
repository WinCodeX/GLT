# app/controllers/admin/sms_messaging_controller.rb
module Admin
  class SmsMessagingController < ApplicationController
    before_action :authenticate_user! # optional security

    def index
      @default_message = "Hi 👋 Glen, your package has been dropped at our agent and is being processed for delivery."
    end

    def create
      @recipients = params[:recipients].to_s.split(',').map(&:strip)
      @message = params[:message]

      if @recipients.blank? || @message.blank?
        flash[:alert] = "Recipients and message cannot be empty."
        redirect_to admin_sms_messaging_index_path and return
      end

      begin
        at = Africastalking::Initialize.new(ENV['AT_USERNAME'], ENV['AT_API_KEY'])
        sms = at.sms
        response = sms.send(message: @message, to: @recipients)

        flash[:notice] = "Bulk SMS queued successfully! Response: #{response.inspect}"
      rescue => e
        flash[:alert] = "Failed to send SMS: #{e.message}"
      end

      redirect_to admin_sms_messaging_index_path
    end
  end
end