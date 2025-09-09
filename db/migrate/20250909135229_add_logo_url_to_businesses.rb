class AddLogoUrlToBusinesses < ActiveRecord::Migration[7.0]
  def change
    add_column :businesses, :logo_url, :string
    add_index :businesses, :logo_url
  end
end