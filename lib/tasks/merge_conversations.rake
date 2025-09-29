# lib/tasks/merge_conversations.rake
namespace :conversations do
  desc "Merge duplicate support conversations for users"
  task merge_duplicates: :environment do
    puts "🔍 Finding users with multiple support conversations..."
    
    # Find all users with multiple support conversations
    duplicate_users = ConversationParticipant
      .joins(:conversation)
      .where(conversations: { conversation_type: 'support_ticket' }, role: 'customer')
      .group(:user_id)
      .having('COUNT(DISTINCT conversation_id) > 1')
      .pluck(:user_id)
    
    puts "📊 Found #{duplicate_users.size} users with multiple support conversations"
    
    duplicate_users.each do |user_id|
      merge_user_conversations(user_id)
    end
    
    puts "✅ Merge completed!"
  end
  
  desc "Merge conversations for specific user"
  task :merge_for_user, [:user_id] => :environment do |t, args|
    user_id = args[:user_id].to_i
    
    unless user_id > 0
      puts "❌ Please provide a valid user_id: rake conversations:merge_for_user[123]"
      exit
    end
    
    merge_user_conversations(user_id)
    puts "✅ Merge completed for user #{user_id}!"
  end
  
  def merge_user_conversations(user_id)
    user = User.find(user_id)
    puts "\n👤 Processing user #{user.id} (#{user.email})"
    
    # Get all support conversations for this user
    conversations = user.conversations
                       .support_tickets
                       .order(:created_at)
                       .to_a
    
    if conversations.size <= 1
      puts "   ℹ️  User has only #{conversations.size} conversation, skipping"
      return
    end
    
    puts "   📋 Found #{conversations.size} conversations to merge"
    
    # Keep the oldest conversation (master)
    master_conversation = conversations.first
    duplicate_conversations = conversations[1..-1]
    
    puts "   🎯 Master conversation: #{master_conversation.id} (created #{master_conversation.created_at})"
    puts "   🗑️  Will merge #{duplicate_conversations.size} duplicate conversations"
    
    ActiveRecord::Base.transaction do
      all_tickets = master_conversation.tickets || []
      
      duplicate_conversations.each do |dup_conv|
        puts "      → Merging conversation #{dup_conv.id}..."
        
        # 1. Collect tickets from duplicate
        dup_tickets = dup_conv.tickets || []
        if dup_tickets.any?
          puts "         • Moving #{dup_tickets.size} tickets"
          all_tickets.concat(dup_tickets)
        end
        
        # 2. Move all messages to master conversation
        message_count = dup_conv.messages.count
        if message_count > 0
          puts "         • Moving #{message_count} messages"
          dup_conv.messages.update_all(conversation_id: master_conversation.id)
        end
        
        # 3. Move unique participants to master
        dup_conv.conversation_participants.each do |participant|
          unless master_conversation.conversation_participants.exists?(user_id: participant.user_id, role: participant.role)
            puts "         • Moving participant: #{participant.user.email} (#{participant.role})"
            participant.update!(conversation_id: master_conversation.id)
          else
            participant.destroy
          end
        end
        
        # 4. Preserve current ticket if it was active
        if dup_conv.current_ticket_id.present?
          puts "         • Preserving active ticket: #{dup_conv.current_ticket_id}"
          master_conversation.current_ticket_id = dup_conv.current_ticket_id
        end
        
        # 5. Delete duplicate conversation
        puts "         • Deleting duplicate conversation #{dup_conv.id}"
        dup_conv.destroy
      end
      
      # Update master conversation with all tickets
      master_conversation.tickets = all_tickets
      master_conversation.customer_id = user.id
      master_conversation.metadata ||= {}
      master_conversation.metadata['total_tickets'] = all_tickets.size
      master_conversation.metadata['merged_at'] = Time.current.iso8601
      master_conversation.metadata['merged_conversations'] = duplicate_conversations.map(&:id)
      
      master_conversation.save!
      
      # Create system message about merge
      system_user = Conversation.send(:find_support_user_for_system_messages)
      master_conversation.messages.create!(
        user: system_user,
        content: "Conversation history consolidated. #{all_tickets.size} tickets merged from #{duplicate_conversations.size + 1} conversations.",
        message_type: 'system',
        is_system: true,
        metadata: { 
          type: 'conversations_merged',
          merged_count: duplicate_conversations.size,
          total_tickets: all_tickets.size
        }
      )
      
      puts "   ✅ Successfully merged into conversation #{master_conversation.id}"
      puts "   📊 Total tickets: #{all_tickets.size}"
      puts "   💬 Total messages: #{master_conversation.messages.count}"
    end
    
  rescue => e
    puts "   ❌ Error merging conversations for user #{user_id}: #{e.message}"
    puts e.backtrace.first(3)
  end
end