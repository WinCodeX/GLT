class AddAcknowledgmentFieldsToMessages < ActiveRecord::Migration[7.1]
  def change
    add_column :messages, :delivered_at, :datetime
    add_column :messages, :read_at, :datetime
    
    add_index :messages, :delivered_at
    add_index :messages, :read_at
  end
end