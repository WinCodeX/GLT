# db/migrate/20250929120000_add_tickets_to_conversations.rb
class AddTicketsToConversations < ActiveRecord::Migration[7.1]
  def change
    # Add tickets array to track multiple tickets per conversation
    add_column :conversations, :tickets, :jsonb, default: []
    add_column :conversations, :current_ticket_id, :string
    
    # Add indexes for better query performance
    add_index :conversations, :tickets, using: :gin
    add_index :conversations, :current_ticket_id
    add_index :conversations, [:conversation_type, :current_ticket_id]
    
    # Add user_id for direct conversation lookup
    add_column :conversations, :customer_id, :bigint
    add_index :conversations, [:customer_id, :conversation_type]
    add_foreign_key :conversations, :users, column: :customer_id
  end
end