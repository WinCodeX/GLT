class Area < ApplicationRecord
  belongs_to :location
  has_many :agents
end
