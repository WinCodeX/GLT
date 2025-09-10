# app/controllers/sessions_controller.rb
class SessionsController < WebApplicationController
  skip_before_action :authenticate_user!, only: [:new, :create, :redirect_root, :dashboard]
  
  # GET / (root path handler)
  def redirect_root
    # Handle API requests - if it's JSON or API path, act like the old root
    if request.format.json? || request.path.start_with?('/api')
      redirect_to '/api/v1/status'
      return
    end
    
    # Handle web requests
    if user_signed_in?
      redirect_based_on_role
    else
      redirect_to sign_in_path
    end
  end

  # GET /sign_in
  def new
    if user_signed_in?
      redirect_based_on_role
      return
    end
    
    @user = User.new
  end

  # POST /sign_in
  def create
    user = User.find_by(email: params[:user][:email])
    
    if user && user.valid_password?(params[:user][:password])
      sign_in(user)
      
      # Role-based redirect after successful sign in
      if user.admin?
        redirect_to dashboard_path, notice: 'Signed in successfully! Choose your dashboard:'
      else
        redirect_to mpesa_payments_path, notice: 'Signed in successfully!'
      end
    else
      flash.now[:alert] = 'Invalid email or password'
      @user = User.new(email: params[:user][:email])
      render :new
    end
  end

  # GET /dashboard (for admin users to choose between admin and mpesa)
  def dashboard
    unless current_user&.admin?
      redirect_to mpesa_payments_path
      return
    end
    
    # This will render app/views/sessions/dashboard.html.erb
    # which gives admin users a choice between admin panel and mpesa payments
  end

  # DELETE /sign_out
  def destroy
    sign_out(current_user)
    redirect_to sign_in_path, notice: 'Signed out successfully!'
  end

  private

  def redirect_based_on_role
    if current_user.admin?
      # Check if they're trying to access admin specifically
      if request.path.start_with?('/admin')
        redirect_to '/admin'
      else
        redirect_to dashboard_path
      end
    else
      redirect_to mpesa_payments_path
    end
  end
end