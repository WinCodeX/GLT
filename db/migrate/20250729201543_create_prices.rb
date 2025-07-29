class CreatePrices < ActiveRecord::Migration[7.1]
  def change
    create_table :prices do |t|
     t.references :origin_area, foreign_key: { to_table: :areas }
      t.references :destination_area, foreign_key: { to_table: :areas }
      t.integer :cost

      t.timestamps
    end
  end
end
