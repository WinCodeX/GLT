# app/controllers/admin/notifications_controller.rb
class Admin::NotificationsController < AdminController
  before_action :set_notification, only: [:destroy, :mark_as_read, :mark_as_unread]  # FIXED: Removed :show since we don't have a show action
  
  # GET /admin/notifications
  def index
    @notifications = Notification.includes(:user, :package)
                                 .order(created_at: :desc)
                                 .limit(20)  # FIXED: Removed .page(), use limit instead
                                 .offset((params[:page].to_i.clamp(1, 999) - 1) * 20)
    
    # Apply filters if present
    @notifications = @notifications.where(notification_type: params[:type]) if params[:type].present?
    @notifications = @notifications.where(read: params[:read] == 'true') if params[:read].present?
    
    @stats = {
      total: Notification.count,
      unread: Notification.where(read: false).count,
      delivered: Notification.where(delivered: true).count
    }
  end
  
  # GET /admin/notifications/new
  def new
    @notification = Notification.new
    @users = User.order(:email).limit(100)
  end
  
  # POST /admin/notifications
  def create
    @notification = Notification.new(notification_params)
    
    if @notification.save
      flash[:success] = 'Notification created successfully'
      redirect_to admin_notifications_path
    else
      @users = User.order(:email).limit(100)
      flash.now[:error] = 'Failed to create notification'
      render :new
    end
  end
  
  # GET /admin/notifications/broadcast_form
  def broadcast_form
    @users = User.order(:email).limit(100)
  end
  
  # POST /admin/notifications/broadcast
  def broadcast
    broadcast_params = params.require(:broadcast).permit(
      :title, :message, :notification_type, :priority, :channel, user_ids: []
    )
    
    target_users = if broadcast_params[:user_ids].present?
      User.where(id: broadcast_params[:user_ids])
    else
      User.all
    end
    
    count = 0
    target_users.find_each do |user|
      user.notifications.create!(
        title: broadcast_params[:title],
        message: broadcast_params[:message],
        notification_type: broadcast_params[:notification_type] || 'general',
        priority: broadcast_params[:priority] || 0,
        channel: broadcast_params[:channel] || 'in_app'
      )
      count += 1
    end
    
    flash[:success] = "Broadcast sent to #{count} users"
    redirect_to admin_notifications_path
  rescue => e
    flash[:error] = "Broadcast failed: #{e.message}"
    redirect_to broadcast_form_admin_notifications_path
  end
  
  # DELETE /admin/notifications/:id
  def destroy
    @notification.destroy
    flash[:success] = 'Notification deleted successfully'
    redirect_to admin_notifications_path
  end
  
  # PATCH /admin/notifications/:id/mark_as_read
  def mark_as_read
    @notification.update(read: true, read_at: Time.current)
    redirect_to admin_notifications_path, notice: 'Notification marked as read'
  end
  
  # PATCH /admin/notifications/:id/mark_as_unread
  def mark_as_unread
    @notification.update(read: false, read_at: nil)
    redirect_to admin_notifications_path, notice: 'Notification marked as unread'
  end
  
  private
  
  def set_notification
    @notification = Notification.find(params[:id])
  end
  
  def notification_params
    params.require(:notification).permit(
      :title, :message, :notification_type, :priority, :channel, 
      :user_id, :package_id, :expires_at
    )
  end
end