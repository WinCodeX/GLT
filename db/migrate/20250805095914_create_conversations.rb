class CreateConversations < ActiveRecord::Migration[7.1]
  def change
    create_table :conversations do |t|
      t.string :conversation_type, null: false
      t.string :title
      t.json :metadata, default: {}
      t.datetime :last_activity_at
      t.timestamps
    end
    
    add_index :conversations, :conversation_type
    add_index :conversations, :last_activity_at
    add_index :conversations, "((metadata->>'status'))", name: 'index_conversations_on_status'
    add_index :conversations, "((metadata->>'ticket_id'))", name: 'index_conversations_on_ticket_id'
  end
end