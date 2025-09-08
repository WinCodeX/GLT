# db/migrate/20250908082310_create_business_categories.rb
class CreateBusinessCategories < ActiveRecord::Migration[7.0]
  def change
    create_table :business_categories do |t|
      t.references :business, null: false, foreign_key: true
      t.references :category, null: false, foreign_key: true

      t.timestamps
    end

    # Only add the unique composite index - Rails automatically creates individual indexes for references
    add_index :business_categories, [:business_id, :category_id], unique: true, name: 'index_business_categories_on_business_and_category'
  end
end