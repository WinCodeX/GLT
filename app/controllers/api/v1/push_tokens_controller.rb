
# app/controllers/api/v1/push_tokens_controller.rb
class Api::V1::PushTokensController < ApplicationController
  before_action :authenticate_user!
  
  # POST /api/v1/push_tokens
  def create
    Rails.logger.info "📱 FCM Push token registration attempt for user #{current_user&.id}"
    Rails.logger.info "📱 Request params: #{sanitized_params}"
    
    platform = token_params[:platform] || params[:platform] || 'fcm'
    token = token_params[:push_token] || params[:push_token]
    
    # Only allow FCM and APNS platforms
    unless ['fcm', 'apns'].include?(platform)
      return render json: {
        success: false,
        message: "Only FCM and APNS platforms are supported",
        errors: ["Invalid platform: #{platform}"]
      }, status: :unprocessable_entity
    end
    
    # Validate token format
    unless valid_token_format?(token, platform)
      Rails.logger.error "❌ Invalid token format for platform #{platform}"
      return render json: {
        success: false,
        message: "Invalid token format for #{platform} platform",
        errors: ["Token format validation failed"]
      }, status: :unprocessable_entity
    end
    
    push_token = current_user.push_tokens.find_or_initialize_by(
      token: token,
      platform: platform
    )
    
    push_token.assign_attributes(
      device_info: token_params[:device_info] || params[:device_info] || {},
      active: true,
      last_used_at: Time.current
    )
    
    if push_token.save
      Rails.logger.info "✅ FCM Push token registered successfully for user #{current_user.id}: #{platform}"
      
      render json: {
        success: true,
        message: 'FCM Push token registered successfully',
        data: {
          id: push_token.id,
          platform: push_token.platform,
          created_at: push_token.created_at,
          token_preview: "#{token[0..20]}#{'...' if token.length > 20}"
        }
      }, status: :created
    else
      Rails.logger.error "❌ FCM Push token registration failed: #{push_token.errors.full_messages}"
      
      render json: {
        success: false,
        message: 'Failed to register FCM push token',
        errors: push_token.errors.full_messages
      }, status: :unprocessable_entity
    end
    
  rescue => e
    Rails.logger.error "❌ FCM Push token controller error: #{e.message}"
    Rails.logger.error "❌ Backtrace: #{e.backtrace.first(5).join("\n")}"
    
    render json: {
      success: false,
      message: 'Internal server error during FCM push token registration',
      error: Rails.env.development? ? e.message : 'Internal server error'
    }, status: :internal_server_error
  end
  
  # DELETE /api/v1/push_tokens/:token
  def destroy
    token = current_user.push_tokens.find_by(token: params[:token])
    
    if token&.destroy
      Rails.logger.info "🗑️ FCM Push token removed for user #{current_user.id}"
      
      render json: {
        success: true,
        message: 'FCM Push token removed successfully'
      }, status: :ok
    else
      render json: {
        success: false,
        message: 'FCM Push token not found'
      }, status: :not_found
    end
    
  rescue => e
    Rails.logger.error "❌ FCM Push token delete error: #{e.message}"
    
    render json: {
      success: false,
      message: 'Error removing FCM push token',
      error: Rails.env.development? ? e.message : 'Internal server error'
    }, status: :internal_server_error
  end
  
  private
  
  def token_params
    if params[:push_token].is_a?(ActionController::Parameters)
      params.require(:push_token).permit(:platform, device_info: {})
    else
      params.permit(:push_token, :platform, device_info: {})
    end
  rescue ActionController::ParameterMissing => e
    Rails.logger.warn "⚠️ Parameter missing, using fallback: #{e.message}"
    params.permit(:push_token, :platform, device_info: {})
  end
  
  def valid_token_format?(token, platform)
    return false if token.blank?
    
    case platform
    when 'fcm'
      # FCM tokens are typically 140+ characters long
      token.length > 100 && token.match?(/^[A-Za-z0-9_:-]+$/)
    when 'apns'
      # APNS tokens are 64 hex characters
      token.length == 64 && token.match?(/^[a-fA-F0-9]+$/)
    else
      false
    end
  end
  
  def sanitized_params
    safe_params = params.to_unsafe_h.deep_dup
    if safe_params[:push_token]
      token = safe_params[:push_token].to_s
      safe_params[:push_token] = "#{token[0..20]}#{'...' if token.length > 20}"
    end
    safe_params
  end
end