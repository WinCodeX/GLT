class CreatePackagePrintLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :package_print_logs do |t|
      t.references :package, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.datetime :printed_at, null: false
      t.string :print_context, null: false, default: 'manual_print'
      t.string :status, null: false, default: 'completed'
      t.integer :copies_printed, default: 1, null: false
      t.json :metadata, default: {}
      t.timestamps

      t.index [:package_id, :printed_at]
      t.index [:user_id, :printed_at]
      t.index [:print_context, :printed_at]
      t.index [:status, :printed_at]
      t.index :printed_at
    end
  end
end