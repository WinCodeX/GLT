# app/models/rider_report.rb
class RiderReport < ApplicationRecord
  belongs_to :user
  belongs_to :rider, optional: true

  enum issue_type: {
    mechanical: 'mechanical',
    weather: 'weather',
    fuel: 'fuel',
    accident: 'accident',
    other: 'other'
  }

  enum status: {
    pending: 'pending',
    acknowledged: 'acknowledged',
    in_progress: 'in_progress',
    resolved: 'resolved',
    closed: 'closed'
  }

  validates :issue_type, presence: true
  validates :description, presence: true
  validates :user, presence: true
  validates :reported_at, presence: true

  scope :recent, -> { order(reported_at: :desc) }
  scope :today, -> { where('reported_at >= ?', Time.current.beginning_of_day) }
  scope :this_week, -> { where('reported_at >= ?', 1.week.ago) }
  scope :unresolved, -> { where.not(status: ['resolved', 'closed']) }
  scope :critical, -> { where(issue_type: ['accident', 'mechanical']) }
  scope :by_rider, ->(rider_id) { where(rider_id: rider_id) }

  before_validation :set_reported_at, on: :create

  def severity
    case issue_type
    when 'accident'
      'critical'
    when 'mechanical', 'weather'
      'high'
    when 'fuel'
      'medium'
    else
      'low'
    end
  end

  def time_to_resolve
    return nil unless resolved_at
    resolved_at - reported_at
  end

  def hours_to_resolve
    return nil unless time_to_resolve
    (time_to_resolve / 1.hour).round(1)
  end

  def mark_acknowledged!
    update!(status: 'acknowledged', acknowledged_at: Time.current)
  end

  def mark_in_progress!
    update!(status: 'in_progress', started_at: Time.current)
  end

  def mark_resolved!(resolution_notes: nil)
    update!(
      status: 'resolved',
      resolved_at: Time.current,
      resolution_notes: resolution_notes
    )
  end

  def as_json(options = {})
    super(options).merge(
      'severity' => severity,
      'hours_to_resolve' => hours_to_resolve,
      'rider_name' => user.display_name || user.name,
      'location' => location_latitude && location_longitude ? {
        latitude: location_latitude,
        longitude: location_longitude
      } : nil
    )
  end

  private

  def set_reported_at
    self.reported_at ||= Time.current
  end
end

# Migration for rider_reports table:
# 
# class CreateRiderReports < ActiveRecord::Migration[7.0]
#   def change
#     create_table :rider_reports do |t|
#       t.references :user, null: false, foreign_key: true
#       t.references :rider, null: true, foreign_key: true
#       t.string :issue_type, null: false
#       t.text :description, null: false
#       t.decimal :location_latitude, precision: 10, scale: 6
#       t.decimal :location_longitude, precision: 10, scale: 6
#       t.datetime :reported_at, null: false
#       t.string :status, default: 'pending', null: false
#       t.datetime :acknowledged_at
#       t.datetime :started_at
#       t.datetime :resolved_at
#       t.text :resolution_notes
#       t.jsonb :metadata, default: {}
#
#       t.timestamps
#     end
#
#     add_index :rider_reports, :issue_type
#     add_index :rider_reports, :status
#     add_index :rider_reports, :reported_at
#   end
# end