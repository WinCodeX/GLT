
# app/jobs/schedule_package_expiry_job.rb
class SchedulePackageExpiryJob < ApplicationJob
  queue_as :default

  def perform(package_id)
    package = Package.find_by(id: package_id)
    return unless package
    
    Rails.logger.info "Checking expiry status for package #{package.code}"
    
    # Check if package is overdue for rejection
    if package.expiry_deadline.present? && package.expiry_deadline <= Time.current
      if package.state.in?(['pending_unpaid', 'pending'])
        reason = case package.state
                when 'pending_unpaid'
                  "Payment not received within deadline"
                when 'pending'
                  "Package not submitted for delivery within deadline"
                else
                  "Package expired"
                end
        
        package.reject_package!(reason: reason, auto_rejected: true)
      end
    # Check if package needs expiry warning
    elsif package.expiry_deadline.present? && 
          package.expiry_deadline <= 6.hours.from_now && 
          package.expiry_deadline > 2.hours.from_now
      
      hours_remaining = ((package.expiry_deadline - Time.current) / 1.hour).round(1)
      
      # Only send warning if not already sent recently
      last_warning = package.notifications
        .where(notification_type: 'final_warning')
        .where('created_at >= ?', 8.hours.ago)
        .exists?
      
      unless last_warning
        Notification.create_expiry_warning(
          package: package,
          hours_remaining: hours_remaining
        )
      end
      
      # Schedule final expiry check
      SchedulePackageExpiryJob.perform_at(package.expiry_deadline, package.id)
    end
  end
end