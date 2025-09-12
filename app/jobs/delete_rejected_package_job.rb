# app/jobs/delete_rejected_package_job.rb
class DeleteRejectedPackageJob < ApplicationJob
  queue_as :low

  def perform(package_id)
    package = Package.find_by(id: package_id)
    return unless package
    
    # Only delete if still rejected and auto-rejected
    if package.rejected? && package.auto_rejected? && package.final_deadline_passed?
      Rails.logger.info "Permanently deleting auto-rejected package: #{package.code}"
      
      begin
        # Create final notification before deletion
        Notification.create!(
          user: package.user,
          package_id: package.id,
          title: "Package #{package.code} Permanently Deleted",
          message: "Your rejected package #{package.code} has been permanently deleted from our system as it was not resubmitted within the allowed timeframe.",
          notification_type: 'general',
          priority: 'normal',
          metadata: {
            package_code: package.code,
            rejected_at: package.rejected_at,
            deletion_reason: 'Auto-deletion after rejection period expired'
          },
          icon: 'trash-2'
        )
        
        # Delete the package
        package.destroy!
        
      rescue => e
        Rails.logger.error "Failed to delete rejected package #{package.code}: #{e.message}"
        
        # Retry in 1 hour if deletion fails
        DeleteRejectedPackageJob.perform_in(1.hour, package_id)
      end
    else
      Rails.logger.info "Package #{package&.code || package_id} not eligible for deletion - skipping"
    end
  end
end