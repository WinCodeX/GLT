class AddPackageSizeToPackages < ActiveRecord::Migration[7.1]
  def change
    add_column :packages, :package_size, :string
  end
end
