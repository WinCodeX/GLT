class User < ApplicationRecord
  # Include default devise modules + JWT
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :jwt_authenticatable, jwt_revocation_strategy: Devise::JWT::RevocationStrategies::Null

  # ActiveStorage for avatar
  has_one_attached :avatar


  has_many :businesses          # These are the businesses the user owns
  has_many :business_memberships
  has_many :joined_businesses, through: :business_memberships, source: :business


  # Rolify for roles
  rolify

  # Default role after creation
  after_create :assign_default_role

  private

  def assign_default_role
    add_role(:client) if roles.blank?
  end
end