# config/initializers/recurring_jobs.rb
Rails.application.config.after_initialize do
  # Only in production and not during asset precompilation
  if Rails.env.production? && !defined?(Rails::Console) && !File.basename($0) == 'rake'
    
    # Start background jobs after a short delay to ensure everything is loaded
    Thread.new do
      sleep 30.seconds  # Wait for full app initialization
      
      Rails.logger.info "Starting recurring package expiry management job..."
      
      begin
        # Process any immediately overdue packages
        Package.process_immediate_overdue_packages!
        
        # Start the recurring job
        PackageExpiryManagementJob.perform_later
        
        Rails.logger.info "Recurring package expiry management job started successfully"
      rescue => e
        Rails.logger.error "Failed to start recurring jobs: #{e.message}"
      end
    end
  end
end