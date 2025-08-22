class AddDeliveryLocationToPackages < ActiveRecord::Migration[7.1]
  def change
    add_column :packages, :delivery_location, :text
  end
end
