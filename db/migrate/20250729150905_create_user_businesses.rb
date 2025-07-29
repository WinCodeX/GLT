class CreateUserBusinesses < ActiveRecord::Migration[7.1]
  def change
    create_table :user_businesses do |t|
      t.references :user, null: false, foreign_key: true
      t.references :business, null: false, foreign_key: true
      t.string :role

      t.timestamps
    end
  end
end
