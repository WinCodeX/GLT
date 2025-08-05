class CreateConversationParticipants < ActiveRecord::Migration[7.1]
  def change
    create_table :conversation_participants do |t|
      t.references :conversation, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, default: 'participant'
      t.datetime :joined_at
      t.datetime :last_read_at
      t.boolean :notifications_enabled, default: true
      t.timestamps
    end

    add_index :conversation_participants, [:conversation_id, :user_id], 
              unique: true, name: 'index_conv_participants_on_conv_and_user'
              
    # 🔥 REMOVE this line — already added by `t.references :user`
    # add_index :conversation_participants, :user_id

    add_index :conversation_participants, :role
  end
end