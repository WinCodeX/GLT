class CreateMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :messages do |t|
      t.references :conversation, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :content
      t.integer :message_type, default: 0
      t.json :metadata, default: {}
      t.boolean :is_system, default: false
      t.datetime :edited_at
      t.timestamps
    end

    # ❌ REMOVE redundant indexes:
    # add_index :messages, :conversation_id
    # add_index :messages, :user_id

    # ✅ KEEP only useful new ones:
    add_index :messages, :message_type
    add_index :messages, :is_system
    add_index :messages, :created_at
  end
end