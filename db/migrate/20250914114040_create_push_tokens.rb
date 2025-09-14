class CreatePushTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :push_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token, null: false
      t.string :platform, null: false # 'expo', 'fcm', 'apns'
      t.json :device_info, default: {}
      t.boolean :active, default: true
      t.integer :failure_count, default: 0
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :push_tokens, [:user_id, :platform]
    add_index :push_tokens, :token, unique: true
    add_index :push_tokens, :active
    add_index :push_tokens, :last_used_at
  end
end