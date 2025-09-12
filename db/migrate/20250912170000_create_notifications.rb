# db/migrate/20250912170000_create_notifications.rb
class CreateNotifications < ActiveRecord::Migration[7.1]
  def change
    create_table :notifications do |t|
      t.references :user, null: false, foreign_key: true
      t.references :package, null: true, foreign_key: true
      t.string :title, null: false
      t.text :message, null: false
      t.string :notification_type, null: false # 'package_rejected', 'package_expired', 'payment_reminder', 'general'
      t.json :metadata, default: {}
      t.boolean :read, default: false
      t.boolean :delivered, default: false
      t.datetime :read_at
      t.datetime :delivered_at
      t.string :channel, default: 'in_app' # 'in_app', 'email', 'sms', 'push'
      t.integer :priority, default: 0 # 0: normal, 1: high, 2: urgent
      t.datetime :expires_at
      t.string :action_url # Optional URL for action buttons
      t.string :icon # Icon name for the notification
      t.string :status, default: 'pending' # 'pending', 'sent', 'failed', 'expired'

      t.timestamps
    end

    add_index :notifications, [:user_id, :read]
    add_index :notifications, [:user_id, :notification_type]
    add_index :notifications, [:package_id]
    add_index :notifications, :created_at
    add_index :notifications, [:expires_at, :status]
    add_index :notifications, [:delivered, :status]
  end
end