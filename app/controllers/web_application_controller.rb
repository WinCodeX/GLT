# app/controllers/web_application_controller.rb
class WebApplicationController < ActionController::Base
  # Include necessary modules for web functionality
  protect_from_forgery with: :exception
  
  # Devise authentication for web requests
  before_action :authenticate_user!
  before_action :configure_permitted_parameters, if: :devise_controller?

  protected

  # Override authenticate_user! to redirect to sign in page for web requests
  def authenticate_user!
    unless user_signed_in?
      redirect_to sign_in_path
      return
    end
  end

  # Configure permitted parameters for Devise
  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [
      :first_name, :last_name, :phone_number
    ])
    
    devise_parameter_sanitizer.permit(:account_update, keys: [
      :first_name, :last_name, :phone_number
    ])
  end

  # Web-specific helper methods
  def current_user_role
    return nil unless current_user
    current_user.primary_role
  end

  def current_user_has_role?(role)
    return false unless current_user
    current_user.has_role?(role.to_sym)
  end
end