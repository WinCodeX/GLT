# config/initializers/recurring_jobs.rb
Rails.application.config.after_initialize do
  # Only run in production, not during asset precompilation, console, or rake tasks
  next unless Rails.env.production?
  next if defined?(Rails::Console)
  next if defined?(Rails::Generators)
  next if File.basename($0) == 'rake'
  next if $0.include?('assets:precompile')
  
  # Add a small delay to ensure full app initialization
  Thread.new do
    begin
      sleep 10.seconds
      
      Rails.logger.info "🚀 INITIALIZER: Starting recurring package expiry management..."
      Rails.logger.info "🔍 INITIALIZER: Current process: #{$0}"
      Rails.logger.info "🔍 INITIALIZER: Rails environment: #{Rails.env}"
      
      # Check if there are packages that need immediate attention
      overdue_count = Package.overdue.count rescue 0
      approaching_count = Package.approaching_deadline.count rescue 0
      deletion_count = Package.rejected_for_deletion.count rescue 0
      
      Rails.logger.info "📦 INITIALIZER: Found #{overdue_count} overdue, #{approaching_count} approaching deadline, #{deletion_count} ready for deletion"
      
      # Process immediate overdue packages if any exist
      if overdue_count > 0 || deletion_count > 0
        Rails.logger.info "🚨 INITIALIZER: Processing immediate overdue packages..."
        result = Package.process_immediate_overdue_packages!
        Rails.logger.info "✅ INITIALIZER: Processed #{result[:rejected]} rejections, #{result[:deleted]} deletions"
      end
      
      # Start the recurring job management
      Rails.logger.info "🔄 INITIALIZER: Starting PackageExpiryManagementJob..."
      PackageExpiryManagementJob.perform_now
      
      Rails.logger.info "✅ INITIALIZER: Recurring package expiry management started successfully"
      
    rescue => e
      Rails.logger.error "❌ INITIALIZER: Failed to start recurring jobs: #{e.class.name} - #{e.message}"
      Rails.logger.error "🔍 INITIALIZER: Backtrace: #{e.backtrace.first(5).join(', ')}"
      
      # Try again in 5 minutes if it failed
      begin
        PackageExpiryManagementJob.set(wait: 5.minutes).perform_later
        Rails.logger.info "🔄 INITIALIZER: Scheduled retry in 5 minutes"
      rescue => retry_error
        Rails.logger.error "❌ INITIALIZER: Even retry scheduling failed: #{retry_error.message}"
      end
    end
  end
end