class AddPhoneNumberToBusinesses < ActiveRecord::Migration[7.0]
  def change
    add_column :businesses, :phone_number, :string
    add_index :businesses, :phone_number
  end
end