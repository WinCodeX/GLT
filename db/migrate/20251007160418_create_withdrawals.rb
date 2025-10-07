class CreateWithdrawals < ActiveRecord::Migration[7.0]
  def change
    create_table :withdrawals do |t|
      t.references :wallet, null: false, foreign_key: true
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.string :phone_number, null: false
      t.string :status, null: false, default: 'pending'
      t.string :withdrawal_method, null: false, default: 'mpesa'
      t.string :reference_number, null: false
      
      # M-Pesa related fields
      t.string :mpesa_receipt_number
      t.string :mpesa_request_id
      t.string :mpesa_conversation_id
      
      # Timestamps
      t.datetime :processed_at
      t.datetime :completed_at
      t.datetime :failed_at
      
      # Failure tracking
      t.text :failure_reason
      
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :withdrawals, :status
    add_index :withdrawals, :reference_number, unique: true
    add_index :withdrawals, :mpesa_receipt_number
    add_index :withdrawals, :mpesa_request_id
    add_index :withdrawals, [:wallet_id, :status]
    add_index :withdrawals, :created_at
  end
end