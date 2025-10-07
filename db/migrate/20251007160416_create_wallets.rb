class CreateWallets < ActiveRecord::Migration[7.0]
  def change
    create_table :wallets do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :wallet_type, null: false, default: 'client'
      t.decimal :balance, precision: 15, scale: 2, default: 0.0, null: false
      t.decimal :pending_balance, precision: 15, scale: 2, default: 0.0, null: false
      t.decimal :total_credited, precision: 15, scale: 2, default: 0.0, null: false
      t.decimal :total_debited, precision: 15, scale: 2, default: 0.0, null: false
      t.boolean :is_active, default: true, null: false
      t.datetime :suspended_at
      t.string :suspension_reason
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :wallets, :wallet_type
    add_index :wallets, :is_active
    add_index :wallets, :balance
  end
end
