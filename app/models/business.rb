class Business < ApplicationRecord
  belongs_to :owner, class_name: "User"
  has_many :user_businesses
  has_many :users, through: :user_businesses
end