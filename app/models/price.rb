class Price < ApplicationRecord
  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true

  belongs_to :origin_agent, class_name: 'Agent', optional: true
  belongs_to :destination_agent, class_name: 'Agent', optional: true

  enum delivery_type: {
    doorstep: 'doorstep',
    agent: 'agent',
    mixed: 'mixed'
  }

  validates :cost, presence: true
end