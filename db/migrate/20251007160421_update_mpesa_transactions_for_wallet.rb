class UpdateMpesaTransactionsForWallet < ActiveRecord::Migration[7.0]
  def change
    # Add wallet reference (if not exists)
    unless column_exists?(:mpesa_transactions, :wallet_id)
      add_reference :mpesa_transactions, :wallet, foreign_key: true, null: true
    end

    # Add transaction type (if not exists)
    unless column_exists?(:mpesa_transactions, :transaction_type)
      add_column :mpesa_transactions, :transaction_type, :string, default: 'package_payment'
      add_index :mpesa_transactions, :transaction_type
    end

    # Add account reference (if not exists)
    unless column_exists?(:mpesa_transactions, :account_reference)
      add_column :mpesa_transactions, :account_reference, :string
      add_index :mpesa_transactions, :account_reference
    end

    # Make package_id nullable since wallet topups don't have packages
    change_column_null :mpesa_transactions, :package_id, true

    # Add timestamps for tracking (if not exists)
    unless column_exists?(:mpesa_transactions, :initiated_at)
      add_column :mpesa_transactions, :initiated_at, :datetime
    end

    unless column_exists?(:mpesa_transactions, :completed_at)
      add_column :mpesa_transactions, :completed_at, :datetime
    end

    unless column_exists?(:mpesa_transactions, :failed_at)
      add_column :mpesa_transactions, :failed_at, :datetime
    end

    # Add mpesa receipt number (if not exists)
    unless column_exists?(:mpesa_transactions, :mpesa_receipt_number)
      add_column :mpesa_transactions, :mpesa_receipt_number, :string
      add_index :mpesa_transactions, :mpesa_receipt_number
    end

    # Add result fields (if not exists)
    unless column_exists?(:mpesa_transactions, :result_code)
      add_column :mpesa_transactions, :result_code, :integer
    end

    unless column_exists?(:mpesa_transactions, :result_description)
      add_column :mpesa_transactions, :result_description, :text
    end

    # Add metadata field (if not exists)
    unless column_exists?(:mpesa_transactions, :transaction_metadata)
      add_column :mpesa_transactions, :transaction_metadata, :jsonb, default: {}
      add_index :mpesa_transactions, :transaction_metadata, using: :gin
    end
  end
end