class AddInitialsToLocations < ActiveRecord::Migration[7.1]
  def change
    add_column :locations, :initials, :string, limit: 3
    add_index :locations, :initials, unique: true
  end
end