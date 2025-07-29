class UserBusiness < ApplicationRecord
  belongs_to :user
  belongs_to :business

  enum role: { owner: "owner", staff: "staff" }
end