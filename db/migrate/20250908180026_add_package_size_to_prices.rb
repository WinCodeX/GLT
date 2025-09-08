class AddPackageSizeToPrices < ActiveRecord::Migration[7.1]
  def change
    add_column :prices, :package_size, :string
  end
end
