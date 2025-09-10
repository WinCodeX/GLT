# app/controllers/admin_controller.rb
class AdminController < WebApplicationController
  # Remove the CSRF skip - this was causing 500 errors
  before_action :authenticate_admin!
  
  protected
  
  def authenticate_admin!
    unless user_signed_in?
      redirect_to sign_in_path, alert: 'Please sign in to access admin area.'
      return
    end
    
    unless current_user.admin?  # This uses your rolify admin? method
      redirect_to sign_in_path, alert: 'Access denied. Admin privileges required.'
      return
    end
  end
end