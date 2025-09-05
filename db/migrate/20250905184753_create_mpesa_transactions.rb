class CreateMpesaTransactions < ActiveRecord::Migration[7.1]
  def change
    create_table :mpesa_transactions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :package, null: false, foreign_key: true
      
      # Daraja API fields
      t.string :checkout_request_id, null: false
      t.string :merchant_request_id, null: false
      t.string :phone_number, null: false
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.string :status, null: false, default: 'pending'
      
      # Callback response fields
      t.integer :result_code
      t.text :result_desc
      t.string :mpesa_receipt_number
      t.string :callback_phone_number
      t.decimal :callback_amount, precision: 10, scale: 2
      
      t.timestamps
    end

    add_index :mpesa_transactions, :checkout_request_id, unique: true
    add_index :mpesa_transactions, :merchant_request_id
    add_index :mpesa_transactions, :status
    add_index :mpesa_transactions, :mpesa_receipt_number
    add_index :mpesa_transactions, [:user_id, :status]
    add_index :mpesa_transactions, [:package_id, :status]
  end
end