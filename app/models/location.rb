class Location < ApplicationRecord
  has_many :areas, dependent: :destroy
  has_many :agents, through: :areas
  
  validates :name, presence: true, uniqueness: true
  
  def areas_count
    areas.count
  end
  
  def agents_count
    agents.count
  end
  
  def can_be_deleted?
    areas.empty?
  end
end