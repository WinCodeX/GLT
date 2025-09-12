# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.redis = {
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
    ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE }
  }
  
  # Configure queues with priorities
  config.queues = %w[critical high default low notifications maintenance]
end

Sidekiq.configure_client do |config|
  config.redis = {
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
    ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE }
  }
end

# Configure logger
Sidekiq.logger.level = Rails.env.production? ? Logger::INFO : Logger::DEBUG

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