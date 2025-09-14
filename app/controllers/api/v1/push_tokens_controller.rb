# app/controllers/api/v1/push_tokens_controller.rb
class Api::V1::PushTokensController < ApplicationController
  before_action :authenticate_user!
  
  # POST /api/v1/push_tokens
  def create
    Rails.logger.info "📱 Push token registration attempt for user #{current_user&.id}"
    Rails.logger.info "📱 Request params: #{params.inspect}"
    
    push_token = current_user.push_tokens.find_or_initialize_by(
      token: token_params[:push_token] || params[:push_token],
      platform: token_params[:platform] || params[:platform] || 'expo'
    )
    
    push_token.assign_attributes(
      device_info: token_params[:device_info] || params[:device_info] || {},
      active: true,
      last_used_at: Time.current
    )
    
    if push_token.save
      Rails.logger.info "✅ Push token registered successfully for user #{current_user.id}: #{push_token.platform}"
      
      render json: {
        success: true,
        message: 'Push token registered successfully',
        data: {
          id: push_token.id,
          platform: push_token.platform,
          created_at: push_token.created_at
        }
      }, status: :created
    else
      Rails.logger.error "❌ Push token registration failed: #{push_token.errors.full_messages}"
      
      render json: {
        success: false,
        message: 'Failed to register push token',
        errors: push_token.errors.full_messages
      }, status: :unprocessable_entity
    end
    
  rescue => e
    Rails.logger.error "❌ Push token controller error: #{e.message}"
    Rails.logger.error "❌ Backtrace: #{e.backtrace.first(5).join("\n")}"
    
    render json: {
      success: false,
      message: 'Internal server error during push token registration',
      error: Rails.env.development? ? e.message : 'Internal server error'
    }, status: :internal_server_error
  end
  
  # DELETE /api/v1/push_tokens/:token
  def destroy
    token = current_user.push_tokens.find_by(token: params[:token])
    
    if token&.destroy
      Rails.logger.info "🗑️ Push token removed for user #{current_user.id}"
      
      render json: {
        success: true,
        message: 'Push token removed successfully'
      }, status: :ok
    else
      render json: {
        success: false,
        message: 'Push token not found'
      }, status: :not_found
    end
    
  rescue => e
    Rails.logger.error "❌ Push token delete error: #{e.message}"
    
    render json: {
      success: false,
      message: 'Error removing push token',
      error: Rails.env.development? ? e.message : 'Internal server error'
    }, status: :internal_server_error
  end
  
  private
  
  def token_params
    if params[:push_token].is_a?(ActionController::Parameters)
      params.require(:push_token).permit(:platform, device_info: {})
    else
      # Fallback for direct parameters
      params.permit(:push_token, :platform, device_info: {})
    end
  rescue ActionController::ParameterMissing => e
    Rails.logger.warn "⚠️ Parameter missing, using fallback: #{e.message}"
    params.permit(:push_token, :platform, device_info: {})
  end
end