# app/models/business.rb
class Business < ApplicationRecord
  belongs_to :owner, class_name: "User"
  has_many :user_businesses, dependent: :destroy
  has_many :users, through: :user_businesses
  has_many :business_invites, dependent: :destroy
  has_many :business_categories, dependent: :destroy
  has_many :categories, through: :business_categories
  
  # Validations
  validates :name, presence: true, length: { minimum: 2, maximum: 100 }
  validates :phone_number, presence: true, format: { 
    with: /\A[\+]?[0-9\-\(\)\s]+\z/, 
    message: "Please enter a valid phone number" 
  }
  validate :categories_limit
  validate :categories_presence

  # Scopes
  scope :with_category, ->(category_slug) { 
    joins(:categories).where(categories: { slug: category_slug }) 
  }
  scope :with_categories, ->(category_slugs) { 
    joins(:categories).where(categories: { slug: category_slugs }).distinct
  }

  # Instance methods
  def category_names
    categories.active.pluck(:name)
  end

  def category_slugs
    categories.active.pluck(:slug)
  end

  def primary_category
    categories.active.first
  end

  def add_categories(category_ids)
    return false if category_ids.blank?
    
    # Limit to 5 categories max
    limited_ids = category_ids.first(5)
    new_categories = Category.active.where(id: limited_ids)
    
    # Add only new categories (avoid duplicates)
    new_categories.each do |category|
      unless categories.include?(category)
        categories << category
      end
    end
    
    valid?
  end

  def remove_category(category_id)
    category = categories.find_by(id: category_id)
    return false unless category
    
    categories.delete(category)
    valid?
  end

  private

  def categories_limit
    if categories.length > 5
      errors.add(:categories, "cannot exceed 5 categories")
    end
  end

  def categories_presence
    if categories.length == 0
      errors.add(:categories, "must have at least one category")
    end
  end
end