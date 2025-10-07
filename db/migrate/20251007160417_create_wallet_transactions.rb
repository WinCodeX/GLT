class CreateWalletTransactions < ActiveRecord::Migration[7.0]
  def change
    create_table :wallet_transactions do |t|
      t.references :wallet, null: false, foreign_key: true
      t.references :package, null: true, foreign_key: true
      t.references :withdrawal, null: true, foreign_key: true
      
      t.string :transaction_type, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.decimal :balance_before, precision: 15, scale: 2, null: false
      t.decimal :balance_after, precision: 15, scale: 2, null: false
      t.string :status, null: false, default: 'completed'
      t.text :description
      t.string :reference
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :wallet_transactions, :transaction_type
    add_index :wallet_transactions, :status
    add_index :wallet_transactions, :reference
    add_index :wallet_transactions, :created_at
    add_index :wallet_transactions, [:wallet_id, :created_at]
  end
end