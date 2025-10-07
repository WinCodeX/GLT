class AddCollectionFieldsToPackages < ActiveRecord::Migration[7.0]
  def change
    add_column :packages, :payment_type, :string, default: 'prepaid', null: false
    add_column :packages, :collection_amount, :decimal, precision: 15, scale: 2
    add_column :packages, :actual_collected_amount, :decimal, precision: 15, scale: 2
    add_column :packages, :collected_by_id, :bigint
    add_column :packages, :collection_metadata, :jsonb, default: {}

    # M-Pesa payment tracking (only if you intend to integrate STK push)
    unless column_exists?(:packages, :payment_request_id)
      add_column :packages, :payment_request_id, :string
      add_column :packages, :payment_merchant_request_id, :string
      add_column :packages, :payment_initiated_at, :datetime
      add_column :packages, :payment_completed_at, :datetime
      add_column :packages, :payment_failed_at, :datetime
      add_column :packages, :payment_failure_reason, :text
      add_column :packages, :payment_metadata, :jsonb, default: {}
    end

    # Indexes
    add_index :packages, :payment_type
    add_index :packages, :collected_by_id
    add_index :packages, [:payment_type, :payment_status] unless index_exists?(:packages, [:payment_type, :payment_status])

    # Foreign key
    add_foreign_key :packages, :users, column: :collected_by_id
  end
end