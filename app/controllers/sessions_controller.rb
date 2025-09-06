# app/controllers/sessions_controller.rb
class SessionsController < ApplicationController
  skip_before_action :authenticate_user!, only: [:new, :create]
  
  # GET /sign_in
  def new
    if user_signed_in?
      redirect_to mpesa_payments_path
      return
    end
    
    @user = User.new
  end

  # POST /sign_in
  def create
    user = User.find_by(email: params[:user][:email])
    
    if user && user.valid_password?(params[:user][:password])
      sign_in(user)
      redirect_to mpesa_payments_path, notice: 'Signed in successfully!'
    else
      flash.now[:alert] = 'Invalid email or password'
      @user = User.new(email: params[:user][:email])
      render :new
    end
  end

  # DELETE /sign_out
  def destroy
    sign_out(current_user)
    redirect_to sign_in_path, notice: 'Signed out successfully!'
  end
end