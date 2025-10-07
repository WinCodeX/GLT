# db/migrate/20251007160415_create_rider_reports.rb
class CreateRiderReports < ActiveRecord::Migration[7.0]
  def change
    create_table :rider_reports do |t|
      t.references :user, null: false, foreign_key: true
      t.references :rider, null: true, foreign_key: true
      t.string :issue_type, null: false
      t.text :description, null: false
      t.decimal :location_latitude, precision: 10, scale: 6
      t.decimal :location_longitude, precision: 10, scale: 6
      t.datetime :reported_at, null: false
      t.string :status, default: 'pending', null: false
      t.datetime :acknowledged_at
      t.datetime :started_at
      t.datetime :resolved_at
      t.text :resolution_notes
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :rider_reports, :issue_type
    add_index :rider_reports, :status
    add_index :rider_reports, :reported_at
    add_index :rider_reports, [:user_id, :status]
    add_index :rider_reports, [:rider_id, :status]
  end
end