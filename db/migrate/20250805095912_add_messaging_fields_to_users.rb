class AddMessagingFieldsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :online, :boolean, default: false
    add_column :users, :last_seen_at, :datetime
    
    add_index :users, :online
  end
end