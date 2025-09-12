
# config/initializers/job_scheduler.rb (Updated for Sidekiq)
Rails.application.configure do
  # Configure Active Job to use Sidekiq
  config.active_job.queue_adapter = :sidekiq
  
  # Configure queue mapping
  config.active_job.queue_name_prefix = Rails.env
  config.active_job.default_queue_name = :default

  # Package expiry management scheduler
  config.after_initialize do
    # Only run scheduler in production or when explicitly enabled
    if Rails.env.production? || ENV['ENABLE_PACKAGE_SCHEDULER'] == 'true'
      Rails.logger.info "Starting Package Management Job Scheduler with Sidekiq..."
      
      # Start the main expiry management job
      PackageExpiryManagementJob.perform_later
      
      Rails.logger.info "Package Management Job Scheduler started successfully"
    else
      Rails.logger.info "Package Management Job Scheduler disabled (set ENABLE_PACKAGE_SCHEDULER=true to enable in development)"
    end
    
    Rails.logger.info "Active Job Queue Adapter: Sidekiq"
  end
end