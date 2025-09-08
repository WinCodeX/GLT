class CreateCategories < ActiveRecord::Migration[7.0]
  def change
    create_table :categories do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.boolean :active, default: true, null: false

      t.timestamps
    end

    add_index :categories, :slug, unique: true
    add_index :categories, :active
    add_index :categories, :name
  end
end