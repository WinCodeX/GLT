# app/controllers/admin/sms_messaging_controller.rb
module Admin
  class SmsMessagingController < AdminController
    protect_from_forgery with: :null_session, only: [:create]

    def index
      # This renders the HTML view
    end

    def create
      phone_number = params[:phone_number].to_s.strip
      message = params[:message].to_s.strip

      if phone_number.blank? || message.blank?
        render json: { 
          success: false, 
          error: "Phone number and message cannot be empty." 
        }, status: :unprocessable_entity
        return
      end

      begin
        service = AfricasTalkingService.new
        response = service.send_sms(
          to: phone_number,
          message: message
        )

        if response[:error]
          render json: { 
            success: false, 
            error: "Failed to send SMS: #{response[:message]}" 
          }, status: :unprocessable_entity
        else
          render json: { 
            success: true, 
            message: "SMS sent successfully!",
            details: response
          }, status: :ok
        end

      rescue => e
        Rails.logger.error "SMS Error: #{e.message}"
        render json: { 
          success: false, 
          error: "Failed to send SMS: #{e.message}" 
        }, status: :internal_server_error
      end
    end
  end
end