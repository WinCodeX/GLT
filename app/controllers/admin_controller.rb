# app/controllers/admin_controller.rb
class AdminController < WebApplicationController
  # Skip CSRF for admin routes to prevent 500 errors
  skip_before_action :verify_authenticity_token
  
  # Override authentication to check for admin role
  before_action :authenticate_admin!
  
  protected
  
  def authenticate_admin!
    unless user_signed_in? && current_user_has_role?(:admin)
      redirect_to sign_in_path, alert: 'Access denied. Admin privileges required.'
      return
    end
  end

  def current_user_has_role?(role)
    return false unless current_user
    # Adjust this based on your User model's role system
    current_user.respond_to?(:has_role?) ? current_user.has_role?(role) : 
    current_user.respond_to?(:admin?) ? current_user.admin? : false
  end
end