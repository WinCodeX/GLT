# lib/tasks/backfill_message_acknowledgments.rake
namespace :messages do
  desc "Backfill delivered_at and read_at for existing messages"
  task backfill_acknowledgments: :environment do
    puts "Starting message acknowledgment backfill..."
    
    total = Message.where(delivered_at: nil).count
    puts "Found #{total} messages to update"
    
    progress = 0
    batch_size = 1000
    
    Message.where(delivered_at: nil).find_in_batches(batch_size: batch_size) do |batch|
      Message.where(id: batch.map(&:id)).update_all(
        "delivered_at = created_at"
      )
      
      progress += batch.size
      puts "Progress: #{progress}/#{total} (#{(progress.to_f / total * 100).round(2)}%)"
    end
    
    puts "✅ Backfill complete!"
  end
end