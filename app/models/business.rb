class Business < ApplicationRecord
  belongs_to :user   # the owner
  has_many :business_memberships
  has_many :members, through: :business_memberships, source: :user
end