# lib/tasks/wallets.rake

namespace :wallets do
  desc "Backfill wallets for all users without wallets"
  task backfill: :environment do
    puts "Starting wallet backfill for users without wallets..."
    
    # Find all users without wallets
    users_without_wallets = User.without_wallet
    total_count = users_without_wallets.count
    
    if total_count.zero?
      puts "✅ All users already have wallets. Nothing to backfill."
      exit 0
    end
    
    puts "Found #{total_count} users without wallets."
    
    print "Do you want to continue? (yes/no): "
    confirmation = STDIN.gets.chomp.downcase
    
    unless confirmation == 'yes' || confirmation == 'y'
      puts "❌ Backfill cancelled."
      exit 0
    end
    
    puts "\nCreating wallets..."
    
    success_count = 0
    error_count = 0
    
    users_without_wallets.find_each.with_index do |user, index|
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
        print "\r✅ Progress: #{index + 1}/#{total_count} (#{success_count} created, #{error_count} errors)"
      rescue => e
        error_count += 1
        puts "\n❌ Failed to create wallet for user #{user.id} (#{user.email}): #{e.message}"
      end
    end
    
    puts "\n\n🎉 Wallet backfill completed!"
    puts "✅ Successfully created: #{success_count}"
    puts "❌ Errors: #{error_count}"
    puts "📊 Total processed: #{total_count}"
  end
  
  desc "Verify all users have wallets"
  task verify: :environment do
    total_users = User.count
    users_with_wallets = User.joins(:wallet).count
    users_without_wallets = total_users - users_with_wallets
    
    puts "\n📊 Wallet Verification Report"
    puts "=" * 50
    puts "Total Users: #{total_users}"
    puts "Users with Wallets: #{users_with_wallets}"
    puts "Users without Wallets: #{users_without_wallets}"
    puts "=" * 50
    
    if users_without_wallets.zero?
      puts "✅ All users have wallets!"
    else
      puts "⚠️  #{users_without_wallets} users need wallets"
      puts "\nRun 'rails wallets:backfill' to create missing wallets"
    end
  end
  
  desc "Show wallet statistics"
  task stats: :environment do
    total_wallets = Wallet.count
    active_wallets = Wallet.active.count
    suspended_wallets = Wallet.suspended.count
    wallets_with_balance = Wallet.with_balance.count
    
    total_balance = Wallet.sum(:balance)
    total_pending = Wallet.sum(:pending_balance)
    total_credited = Wallet.sum(:total_credited)
    total_debited = Wallet.sum(:total_debited)
    
    rider_wallets = Wallet.riders.count
    client_wallets = Wallet.clients.count
    
    puts "\n💰 Wallet Statistics"
    puts "=" * 50
    puts "Total Wallets: #{total_wallets}"
    puts "Active Wallets: #{active_wallets}"
    puts "Suspended Wallets: #{suspended_wallets}"
    puts "Wallets with Balance: #{wallets_with_balance}"
    puts "\nWallet Types:"
    puts "  Rider Wallets: #{rider_wallets}"
    puts "  Client Wallets: #{client_wallets}"
    puts "\nFinancial Summary:"
    puts "  Total Balance: KES #{total_balance.round(2)}"
    puts "  Total Pending: KES #{total_pending.round(2)}"
    puts "  Total Credited: KES #{total_credited.round(2)}"
    puts "  Total Debited: KES #{total_debited.round(2)}"
    puts "=" * 50
  end
end