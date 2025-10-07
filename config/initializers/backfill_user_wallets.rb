# config/initializers/backfill_user_wallets.rb

Rails.application.config.after_initialize do
  # Only run in development or when explicitly triggered
  # To run in production, use a rake task instead
  next unless Rails.env.development?
  
  # Run asynchronously to not block app startup
  Thread.new do
    begin
      # Wait for app to fully initialize
      sleep 5
      
      # Check if User and Wallet models are available
      next unless defined?(User) && defined?(Wallet)
      
      Rails.logger.info "Starting wallet backfill for users without wallets..."
      
      # Find all users without wallets
      users_without_wallets = User.without_wallet
      total_count = users_without_wallets.count
      
      if total_count.zero?
        Rails.logger.info "All users already have wallets. Nothing to backfill."
        next
      end
      
      Rails.logger.info "Found #{total_count} users without wallets. Creating wallets..."
      
      success_count = 0
      error_count = 0
      
      users_without_wallets.find_each do |user|
        begin
          # Determine wallet type based on user role
          wallet_type = if user.has_role?(:rider)
                         'rider'
                       elsif user.has_role?(:agent)
                         'agent'
                       elsif user.respond_to?(:owned_businesses) && user.owned_businesses.any?
                         'business'
                       else
                         'client'
                       end
          
          Wallet.create!(
            user: user,
            wallet_type: wallet_type,
            balance: 0.0,
            pending_balance: 0.0,
            total_credited: 0.0,
            total_debited: 0.0,
            is_active: true
          )
          
          success_count += 1
          Rails.logger.info "Created #{wallet_type} wallet for user #{user.id} (#{user.email})"
        rescue => e
          error_count += 1
          Rails.logger.error "Failed to create wallet for user #{user.id}: #{e.message}"
        end
      end
      
      Rails.logger.info "Wallet backfill completed: #{success_count} created, #{error_count} errors"
    rescue => e
      Rails.logger.error "Wallet backfill process failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end
  end
end