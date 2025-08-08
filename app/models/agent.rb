# app/models/agent.rb
class Agent < ApplicationRecord
  belongs_to :location
  has_one :area, through: :location
  
  validates :name, presence: true
  validates :phone, presence: true, uniqueness: true
  
  scope :active, -> { where(active: true) }
  scope :in_area, ->(area) { joins(:location).where(locations: { area: area }) }
  
  def full_address
    "#{name}, #{location.full_name}"
  end
  
  def display_name
    "#{name} (#{location.name})"
  end
end