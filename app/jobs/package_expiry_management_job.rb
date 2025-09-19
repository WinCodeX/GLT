
# app/jobs/package_expiry_management_job.rb
class PackageExpiryManagementJob < ApplicationJob
  queue_as :high

  def perform
    Rails.logger.info "Starting package expiry management job..."
    
    begin
      # Send warnings for packages approaching deadline
      warning_count = send_expiry_warnings!
      
      # Auto-reject expired packages
      rejection_count = auto_reject_expired_packages!
      
      # Delete permanently rejected packages
      deletion_count = delete_expired_rejected_packages!
      
      Rails.logger.info "Package expiry management completed: #{warning_count} warnings, #{rejection_count} rejections, #{deletion_count} deletions"
      
      # Schedule next run (every 30 minutes)
      PackageExpiryManagementJob.set(wait: 30.minutes).perform_later
      
    rescue => e
      Rails.logger.error "Package expiry management job failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      # Retry in 30 minutes on failure
      PackageExpiryManagementJob.set(wait: 30.minutes).perform_later
    end
  end
  
  private
  
  def send_expiry_warnings!
    warned_count = 0
    
    Package.approaching_deadline.find_each do |package|
      hours_remaining = package.hours_until_expiry
      next unless hours_remaining && hours_remaining > 0
      
      # Only send warning once when between 2-6 hours remain
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
        warned_count += 1
      end
    end
    
    Rails.logger.info "Sent expiry warnings for #{warned_count} packages"
    warned_count
  end
  
  def auto_reject_expired_packages!
    rejected_count = 0
    
    Package.overdue.where(state: ['pending_unpaid', 'pending']).find_each do |package|
      reason = case package.state
               when 'pending_unpaid'
                 "Payment not received within deadline"
               when 'pending'
                 "Package not submitted for delivery within deadline"
               else
                 "Package expired"
               end
      
      if package.reject_package!(reason: reason, auto_rejected: true)
        # Send rejection notification
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
        rejected_count += 1
      end
    end
    
    Rails.logger.info "Auto-rejected #{rejected_count} expired packages"
    rejected_count
  end
  
  def delete_expired_rejected_packages!
    deleted_count = 0
    
    Package.rejected_for_deletion.find_each do |package|
      begin
        Rails.logger.info "Deleting permanently rejected package: #{package.code}"
        package.destroy!
        deleted_count += 1
      rescue => e
        Rails.logger.error "Failed to delete package #{package.code}: #{e.message}"
      end
    end
    
    Rails.logger.info "Deleted #{deleted_count} permanently rejected packages"
    deleted_count
  end
end