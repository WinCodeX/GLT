# app/models/package.rb
class Package < ApplicationRecord
  belongs_to :user

  belongs_to :origin_area, class_name: 'Area', optional: true
  belongs_to :destination_area, class_name: 'Area', optional: true

  belongs_to :origin_agent, class_name: 'Agent', optional: true
  belongs_to :destination_agent, class_name: 'Agent', optional: true

  enum delivery_type: { doorstep: 'doorstep', agent: 'agent', mixed: 'mixed' }
  enum state: {
    pending_unpaid: 'pending_unpaid',
    pending: 'pending',
    submitted: 'submitted',
    in_transit: 'in_transit',
    delivered: 'delivered',
    collected: 'collected',
    rejected: 'rejected'
  }

  validates :delivery_type, :state, :cost, presence: true
end