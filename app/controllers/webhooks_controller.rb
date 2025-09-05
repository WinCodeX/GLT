# app/controllers/webhooks_controller.rb
class WebhooksController < ApplicationController
  skip_before_action :authenticate_user!

  # POST /webhooks/payment/success
  def payment_success
    Rails.logger.info "Payment success webhook: #{params.inspect}"
    
    # You can redirect to M-Pesa callback or handle other payment providers here
    # For M-Pesa, the actual callback is handled in MpesaController#callback
    
    render json: { status: 'success', message: 'Payment success acknowledged' }
  end

  # POST /webhooks/payment/failed
  def payment_failed
    Rails.logger.info "Payment failed webhook: #{params.inspect}"
    
    render json: { status: 'success', message: 'Payment failure acknowledged' }
  end

  # Additional webhook handlers for your existing routes
  def tracking_update
    Rails.logger.info "Tracking update webhook: #{params.inspect}"
    render json: { status: 'success' }
  end

  def delivery_notification
    Rails.logger.info "Delivery notification webhook: #{params.inspect}"
    render json: { status: 'success' }
  end

  def printer_status_update
    Rails.logger.info "Printer status update webhook: #{params.inspect}"
    render json: { status: 'success' }
  end

  def printer_error
    Rails.logger.info "Printer error webhook: #{params.inspect}"
    render json: { status: 'success' }
  end

  def thermal_printer_status_update
    Rails.logger.info "Thermal printer status update webhook: #{params.inspect}"
    render json: { status: 'success' }
  end

  def thermal_printer_error
    Rails.logger.info "Thermal printer error webhook: #{params.inspect}"
    render json: { status: 'success' }
  end

  def scan_completed
    Rails.logger.info "Scan completed webhook: #{params.inspect}"
    render json: { status: 'success' }
  end

  def bulk_scan_completed
    Rails.logger.info "Bulk scan completed webhook: #{params.inspect}"
    render json: { status: 'success' }
  end

  def qr_generation_completed
    Rails.logger.info "QR generation completed webhook: #{params.inspect}"
    render json: { status: 'success' }
  end

  def thermal_qr_generated
    Rails.logger.info "Thermal QR generated webhook: #{params.inspect}"
    render json: { status: 'success' }
  end

  def google_auth_success
    Rails.logger.info "Google auth success webhook: #{params.inspect}"
    render json: { status: 'success' }
  end

  def google_auth_failure
    Rails.logger.info "Google auth failure webhook: #{params.inspect}"
    render json: { status: 'success' }
  end
end