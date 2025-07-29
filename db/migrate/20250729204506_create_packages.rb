class CreatePackages < ActiveRecord::Migration[7.1]
  def change
    create_table :packages do |t|
      t.string :sender_name
      t.string :sender_phone
      t.string :receiver_name
      t.string :receiver_phone
      t.references :origin_area, foreign_key: { to_table: :areas }
      t.references :destination_area, foreign_key: { to_table: :areas }
      t.references :origin_agent, foreign_key: { to_table: :agents }
      t.references :destination_agent, foreign_key: { to_table: :agents }
      t.references :user, null: false, foreign_key: true
      t.string :delivery_type
      t.string :state
      t.integer :cost

      t.timestamps
    end
  end
end
