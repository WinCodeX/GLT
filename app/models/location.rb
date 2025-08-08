# app/models/location.rb
class Location < ApplicationRecord
  belongs_to :area
  has_many :agents, dependent: :restrict_with_error
  
  # Package associations (if packages reference specific locations)
  has_many :origin_packages, class_name: 'Package', foreign_key: 'origin_location_id', dependent: :restrict_with_error
  has_many :destination_packages, class_name: 'Package', foreign_key: 'destination_location_id', dependent: :restrict_with_error
  
  validates :name, presence: true, uniqueness: { scope: :area_id }
  
  # Scopes
  scope :active, -> { joins(:agents).where(agents: { active: true }).distinct }
  
  def full_name
    "#{name}, #{area.name}"
  end
  
  def package_count
    origin_packages.count + destination_packages.count
  end
  
  def active_agents_count
    agents.where(active: true).count
  rescue
    agents.count
  end
  
  def can_be_deleted?
    package_count == 0 && agents.count == 0
  end
end

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