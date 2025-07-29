class User < ApplicationRecord
  rolify
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
devise :database_authenticatable, :registerable,
       :recoverable, :rememberable, :validatable,
       :jwt_authenticatable, jwt_revocation_strategy: Devise::JWT::RevocationStrategies::Null



has_one_attached :avatar

  rolify
  after_create :assign_default_role

  def assign_default_role
    self.add_role(:client) if self.roles.blank?
  end
end
