# app/models/business_category.rb
class BusinessCategory < ApplicationRecord
  belongs_to :business
  belongs_to :category

  validates :business_id, uniqueness: { scope: :category_id, message: "Category already added to this business" }
  validates :business, presence: true
  validates :category, presence: true
  
  # Ensure category is active when added
  validate :category_must_be_active

  private

  def category_must_be_active
    if category && !category.active?
      errors.add(:category, "must be active")
    end
  end
end