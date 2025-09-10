class AdminController < WebApplicationController
  # Skip CSRF for admin routes to prevent 500 errors
  skip_before_action :verify_authenticity_token
  
  # Override authentication to check for admin role
  before_action :authenticate_admin!
  
  protected
  
  def authenticate_admin!
    unless user_signed_in? && current_user.admin?
      redirect_to sign_in_path, alert: 'Access denied. Admin privileges required.'
      return
    end
  end
end