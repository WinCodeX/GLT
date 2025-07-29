class User < ApplicationRecord
  # Include default devise modules + JWT
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :jwt_authenticatable, jwt_revocation_strategy: Devise::JWT::RevocationStrategies::Null

  # ActiveStorage for avatar
  has_one_attached :avatar


  
  has_many :owned_businesses, class_name: "Business", foreign_key: "owner_id"
  has_many :user_businesses
  has_many :businesses, through: :user_businesses


  # Rolify for roles
  rolify

  # Default role after creation
  after_create :assign_default_role

  private

  def assign_default_role
    add_role(:client) if roles.blank?
  end
end