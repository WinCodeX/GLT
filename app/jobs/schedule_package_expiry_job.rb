
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
        
        if package.reject_package!(reason: reason, auto_rejected: true)
          # Send immediate rejection notification
          NotificationCreatorService.create_package_notification(
            package,
            'package_rejected',
            {
              title: "Package #{package.code} Auto-Rejected",
              message: reason,
              priority: 'high',
              icon: 'x-circle',
              action_url: "/packages/#{package.id}",
              metadata: {
                rejection_reason: reason,
                auto_rejected: true,
                can_resubmit: package.can_be_resubmitted?
              }
            }
          )
        end
      end
    # Check if package needs expiry warning
    elsif package.expiry_deadline.present? && 
          package.expiry_deadline <= 6.hours.from_now && 
          package.expiry_deadline > 2.hours.from_now
      
      hours_remaining = ((package.expiry_deadline - Time.current) / 1.hour).round(1)
      
      # Only send warning if not already sent recently
      last_warning = package.notifications
        .where(notification_type: 'expiry_warning')
        .where('created_at >= ?', 8.hours.ago)
        .exists?
      
      unless last_warning
        NotificationCreatorService.create_package_notification(
          package,
          'expiry_warning',
          {
            title: "Package #{package.code} Expiring Soon",
            message: "Your package expires in #{hours_remaining.round(1)} hours. Please take action to avoid auto-rejection.",
            priority: 'high',
            icon: 'clock',
            action_url: "/packages/#{package.id}",
            metadata: {
              hours_remaining: hours_remaining.round(1),
              expiry_deadline: package.expiry_deadline
            }
          }
        )
      end
      
      # Schedule final expiry check
      SchedulePackageExpiryJob.set(wait_until: package.expiry_deadline).perform_later(package.id)
    end
  end
end