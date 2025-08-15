class CreatePackageTrackingEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :package_tracking_events do |t|
      t.references :package, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :event_type, null: false
      t.json :metadata, default: {}
      t.timestamps

      t.index [:package_id, :created_at]
      t.index [:user_id, :created_at]
      t.index [:event_type, :created_at]
      t.index :created_at
      t.index [:package_id, :event_type]
    end
  end
end