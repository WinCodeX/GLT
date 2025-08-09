class Agent < ApplicationRecord
  belongs_to :area
  belongs_to :user
  has_one :location, through: :area
  
  validates :name, presence: true
  validates :phone, presence: true, uniqueness: true
  
  scope :active, -> { where(active: true) }
  scope :in_location, ->(location) { joins(:area).where(areas: { location: location }) }
  scope :in_area, ->(area) { where(area: area) }
  
  def full_address
    "#{name}, #{area.full_name}"
  end
  
  def display_name
    "#{name} (#{area.name})"
  end
  
  def location_name
    area.location.name
  end
end