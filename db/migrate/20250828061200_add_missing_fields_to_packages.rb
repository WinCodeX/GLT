class AddMissingFieldsToPackages < ActiveRecord::Migration[7.1]
  def change
    add_column :packages, :pickup_location, :text
    add_column :packages, :package_description, :text
  end
end
