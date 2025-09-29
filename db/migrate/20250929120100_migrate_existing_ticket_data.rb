# db/migrate/20250929120100_migrate_existing_ticket_data.rb
class MigrateExistingTicketData < ActiveRecord::Migration[7.1]
  def up
    Conversation.where(conversation_type: 'support_ticket').find_each do |conversation|
      next if conversation.tickets.present? # Already migrated
      
      # Extract old ticket data from metadata
      old_ticket_id = conversation.metadata['ticket_id']
      next unless old_ticket_id
      
      # Build ticket object from metadata
      ticket_data = {
        'ticket_id' => old_ticket_id,
        'category' => conversation.metadata['category'] || 'general',
        'priority' => conversation.metadata['priority'] || 'normal',
        'subject' => conversation.metadata['subject'] || 'General Support',
        'status' => conversation.metadata['status'] || 'pending',
        'created_at' => (conversation.metadata['created_at'] || conversation.created_at).to_s,
        'package_id' => conversation.metadata['package_id'],
        'package_code' => conversation.metadata['package_code']
      }.compact
      
      # Add to tickets array
      conversation.tickets = [ticket_data]
      
      # Set current_ticket_id (only if not closed)
      if conversation.metadata['status'] != 'closed'
        conversation.current_ticket_id = old_ticket_id
      end
      
      # Set customer_id from participant
      customer_participant = conversation.conversation_participants.find_by(role: 'customer')
      conversation.customer_id = customer_participant.user_id if customer_participant
      
      conversation.save!(validate: false)
      
      puts "Migrated conversation #{conversation.id} - Ticket: #{old_ticket_id}"
    end
  end
  
  def down
    # Revert changes if needed
    Conversation.where(conversation_type: 'support_ticket').update_all(
      tickets: [],
      current_ticket_id: nil,
      customer_id: nil
    )
  end
end