# config/initializers/job_scheduler.rb
Rails.application.configure do
  # Configure Active Job to use Sidekiq
  config.active_job.queue_adapter = :sidekiq
  config.active_job.queue_name_prefix = Rails.env
  config.active_job.default_queue_name = :default

  config.after_initialize do
    next unless Rails.env.production?
    next if defined?(Rails::Console)
    next if File.basename($0) == 'rake'
    
    Thread.new do
      sleep 15.seconds  # Wait for Sidekiq to be ready
      
      begin
        Rails.logger.info "Starting Package Management Job Scheduler with Sidekiq..."
        
        # Use perform_now for guaranteed execution during startup
        PackageExpiryManagementJob.perform_now
        
        Rails.logger.info "Package Management Job Scheduler started successfully"
      rescue => e
        Rails.logger.error "Failed to start package scheduler: #{e.message}"
      end
    end
  end
end