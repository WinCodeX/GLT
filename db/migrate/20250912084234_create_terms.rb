# db/migrate/xxx_create_terms.rb
class CreateTerms < ActiveRecord::Migration[7.0]
  def change
    create_table :terms do |t|
      t.string :title, null: false
      t.text :content, null: false
      t.string :version, null: false
      t.integer :term_type, default: 0, null: false
      t.boolean :active, default: false, null: false
      t.text :summary
      t.datetime :effective_date
      t.timestamps
    end

    add_index :terms, [:term_type, :active]
    add_index :terms, :version, unique: true
    add_index :terms, [:term_type, :version]
  end
end