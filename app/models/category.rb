# app/models/category.rb
class Category < ApplicationRecord
  has_many :business_categories, dependent: :destroy
  has_many :businesses, through: :business_categories

  validates :name, presence: true, uniqueness: { case_sensitive: false }, length: { minimum: 2, maximum: 50 }
  validates :slug, presence: true, uniqueness: { case_sensitive: false }
  validates :description, length: { maximum: 500 }
  
  scope :active, -> { where(active: true) }
  scope :alphabetical, -> { order(:name) }
  
  before_validation :generate_slug, if: :name_changed?

  def to_param
    slug
  end

  private

  def generate_slug
    self.slug = name.parameterize if name.present?
  end
end