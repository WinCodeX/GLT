# config/initializers/job_scheduler.rb
Rails.application.configure do
  # Configure Active Job queue adapter
  if Rails.env.production?
    # Use a proper queue adapter in production (uncomment one based on your setup)
    # config.active_job.queue_adapter = :sidekiq
    # config.active_job.queue_adapter = :delayed_job
    # config.active_job.queue_adapter = :resque
    config.active_job.queue_adapter = :async # Temporary for production
  else
    # Use async adapter for development/test
    config.active_job.queue_adapter = :async
  end

  # Package expiry management scheduler
  config.after_initialize do
    # Only run scheduler in production or when explicitly enabled
    if Rails.env.production? || ENV['ENABLE_PACKAGE_SCHEDULER'] == 'true'
      Rails.logger.info "🚀 Starting Package Management Job Scheduler..."
      
      # Start the main expiry management job
      PackageExpiryManagementJob.perform_later
      
      Rails.logger.info "✅ Package Management Job Scheduler started successfully"
    else
      Rails.logger.info "⏸️ Package Management Job Scheduler disabled (set ENABLE_PACKAGE_SCHEDULER=true to enable in development)"
    end
    
    # Always log active job configuration
    Rails.logger.info "🔧 Active Job Queue Adapter: #{Rails.application.config.active_job.queue_adapter}"
  end
end