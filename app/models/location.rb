# app/models/location.rb
class Location < ApplicationRecord
  has_many :areas, dependent: :destroy
  has_many :agents, through: :areas
  
  validates :name, presence: true, uniqueness: true
  validates :initials, presence: true, uniqueness: true, 
            format: { with: /\A[A-Z]{2,3}\z/, message: "must be 2-3 uppercase letters" }
  
  # Callbacks
  before_validation :generate_initials, if: -> { initials.blank? && name.present? }
  before_validation :upcase_initials
  
  def areas_count
    areas.count
  end
  
  def agents_count
    agents.count
  end
  
  def can_be_deleted?
    areas.empty?
  end
  
  # Safe initials method that handles missing initials column
  def safe_initials
    return initials if respond_to?(:initials) && initials.present?
    generate_initials_from_name(name)
  end
  
  private
  
  def generate_initials
    self.initials = generate_initials_from_name(name)
    ensure_unique_initials
  end
  
  def generate_initials_from_name(location_name)
    return '' if location_name.blank?
    
    # Extract first letters of significant words, excluding common words
    exclude_words = %w[the and or of in on at to from]
    
    words = location_name.downcase.split(/\s+/).reject { |word| exclude_words.include?(word) }
    
    if words.length >= 2
      # Take first letter of first two significant words
      (words[0][0] + words[1][0]).upcase
    else
      # Take first 3 letters of the name
      location_name.gsub(/[^A-Za-z]/, '')[0, 3].upcase
    end
  end
  
  def ensure_unique_initials
    return unless initials.present?
    
    counter = 1
    base_initials = initials
    while Location.where.not(id: id).exists?(initials: initials)
      self.initials = "#{base_initials}#{counter}"
      counter += 1
    end
  end
  
  def upcase_initials
    self.initials = initials&.upcase
  end
end