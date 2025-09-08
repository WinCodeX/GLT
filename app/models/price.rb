
# app/models/price.rb
class Price < ApplicationRecord
  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true
  belongs_to :origin_agent, class_name: 'Agent', optional: true
  belongs_to :destination_agent, class_name: 'Agent', optional: true

  enum delivery_type: {
  doorstep: 'doorstep',
  home: 'home',
  office: 'office',
  agent: 'agent',
  fragile: 'fragile',
  collection: 'collection',
  mixed: 'mixed'
}

  validates :cost, presence: true, numericality: { greater_than: 0 }
  validates :delivery_type, presence: true
  
  # Ensure at least origin_area or origin_agent is present
  validate :has_origin_reference
  validate :has_destination_reference
  
  scope :for_route, ->(origin_area, destination_area, delivery_type) {
    where(origin_area: origin_area, destination_area: destination_area, delivery_type: delivery_type)
  }
  
  def self.find_cost(origin_area, destination_area, delivery_type)
    find_by(origin_area: origin_area, destination_area: destination_area, delivery_type: delivery_type)&.cost
  end
  
  def route_description
    origin = origin_area&.name || origin_agent&.area&.name || "Unknown"
    destination = destination_area&.name || destination_agent&.area&.name || "Unknown"
    "#{origin} → #{destination} (#{delivery_type.titleize})"
  end
  
  private
  
  def has_origin_reference
    errors.add(:base, "Must have either origin_area or origin_agent") if origin_area.blank? && origin_agent.blank?
  end
  
  def has_destination_reference
    errors.add(:base, "Must have either destination_area or destination_agent") if destination_area.blank? && destination_agent.blank?
  end
end