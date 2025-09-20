class AddBusinessFieldsToPackages < ActiveRecord::Migration[7.1]
  def change
    add_reference :packages, :business, foreign_key: true, null: true
    add_column :packages, :business_name, :string
    add_column :packages, :business_phone, :string
    
    # Add indexes for better query performance
    add_index :packages, [:business_id, :created_at], order: { created_at: :desc }
    add_index :packages, :business_name
  end
end