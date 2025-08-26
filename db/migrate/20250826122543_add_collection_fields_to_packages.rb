# db/migrate/20250826_add_collection_fields_to_packages.rb
class AddCollectionFieldsToPackages < ActiveRecord::Migration[7.0]
  def change
    # Add collection-specific fields
    add_column :packages, :shop_name, :string
    add_column :packages, :shop_contact, :string
    add_column :packages, :collection_address, :text
    add_column :packages, :items_to_collect, :text
    add_column :packages, :item_value, :decimal, precision: 10, scale: 2
    add_column :packages, :item_description, :text
    
    # Add payment and handling fields
    add_column :packages, :payment_method, :string, default: 'mpesa'
    add_column :packages, :payment_status, :string, default: 'pending'
    add_column :packages, :payment_reference, :string
    add_column :packages, :special_instructions, :text
    
    # Add priority and handling flags
    add_column :packages, :priority_level, :string, default: 'normal'
    add_column :packages, :special_handling, :boolean, default: false
    add_column :packages, :requires_payment_advance, :boolean, default: false
    add_column :packages, :collection_type, :string
    
    # Add location coordinates for precise pickup/delivery
    add_column :packages, :pickup_latitude, :decimal, precision: 10, scale: 6
    add_column :packages, :pickup_longitude, :decimal, precision: 10, scale: 6
    add_column :packages, :delivery_latitude, :decimal, precision: 10, scale: 6
    add_column :packages, :delivery_longitude, :decimal, precision: 10, scale: 6
    
    # Add timestamps for collection workflow
    add_column :packages, :payment_deadline, :datetime
    add_column :packages, :collection_scheduled_at, :datetime
    add_column :packages, :collected_at, :datetime
    
    # Add indexes for performance (these ARE valuable)
    add_index :packages, :payment_status
    add_index :packages, :priority_level
    add_index :packages, :collection_type
    add_index :packages, [:delivery_type, :state]
    add_index :packages, [:payment_status, :state]
    add_index :packages, :collection_scheduled_at
  end
  
  def down
    # Clean rollback without constraint complexity
    remove_index :packages, :payment_status if index_exists?(:packages, :payment_status)
    remove_index :packages, :priority_level if index_exists?(:packages, :priority_level)
    remove_index :packages, :collection_type if index_exists?(:packages, :collection_type)
    remove_index :packages, [:delivery_type, :state] if index_exists?(:packages, [:delivery_type, :state])
    remove_index :packages, [:payment_status, :state] if index_exists?(:packages, [:payment_status, :state])
    remove_index :packages, :collection_scheduled_at if index_exists?(:packages, :collection_scheduled_at)
    
    remove_column :packages, :shop_name
    remove_column :packages, :shop_contact
    remove_column :packages, :collection_address
    remove_column :packages, :items_to_collect
    remove_column :packages, :item_value
    remove_column :packages, :item_description
    
    remove_column :packages, :payment_method
    remove_column :packages, :payment_status
    remove_column :packages, :payment_reference
    remove_column :packages, :special_instructions
    
    remove_column :packages, :priority_level
    remove_column :packages, :special_handling
    remove_column :packages, :requires_payment_advance
    remove_column :packages, :collection_type
    
    remove_column :packages, :pickup_latitude
    remove_column :packages, :pickup_longitude
    remove_column :packages, :delivery_latitude
    remove_column :packages, :delivery_longitude
    
    remove_column :packages, :payment_deadline
    remove_column :packages, :collection_scheduled_at
    remove_column :packages, :collected_at
  end
end