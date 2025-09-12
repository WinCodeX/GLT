# app/jobs/package_expiry_management_job.rb
class PackageExpiryManagementJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info "Starting package expiry management job..."
    
    begin
      # Send warnings for packages approaching deadline
      warning_count = Package.send_expiry_warnings!
      
      # Auto-reject expired packages
      rejection_count = Package.auto_reject_expired_packages!
      
      # Delete permanently rejected packages
      deletion_count = Package.delete_expired_rejected_packages!
      
      Rails.logger.info "Package expiry management completed: #{warning_count} warnings, #{rejection_count} rejections, #{deletion_count} deletions"
      
      # Schedule next run (every hour)
      PackageExpiryManagementJob.perform_in(1.hour)
      
    rescue => e
      Rails.logger.error "Package expiry management job failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      # Retry in 30 minutes on failure
      PackageExpiryManagementJob.perform_in(30.minutes)
    end
  end
end
