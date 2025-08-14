# app/models/location.rb
class Location < ApplicationRecord
  has_many :areas, dependent: :destroy
  has_many :agents, through: :areas
  has_many :riders, through: :areas  # Added for scanning system
  has_many :warehouse_staff, dependent: :destroy  # Added for scanning system
  
  validates :name, presence: true, uniqueness: true
  validates :initials, presence: true, uniqueness: true, 
            format: { with: /\A[A-Z]{2,3}\z/, message: "must be 2-3 uppercase letters" }
  
  # Callbacks
  before_validation :generate_initials, if: -> { initials.blank? && name.present? }
  before_validation :upcase_initials
  
  # Scopes
  scope :with_areas, -> { joins(:areas).distinct }  # Added
  scope :with_staff, -> { joins(:warehouse_staff).distinct }  # Added
  
  def areas_count
    areas.count
  end
  
  def agents_count
    agents.count
  end
  
  def riders_count  # Added for scanning system
    riders.count
  end
  
  def warehouse_staff_count  # Added for scanning system
    warehouse_staff.count
  end
  
  def total_staff_count  # Added for scanning system
    agents_count + riders_count + warehouse_staff_count
  end
  
  def active_warehouse_staff_count  # Added for scanning system
    warehouse_staff.where(active: true).count
  rescue
    warehouse_staff.count
  end
  
  def can_be_deleted?
    areas.empty? && warehouse_staff.empty?  # Updated
  end
  
  # Package-related methods through areas
  def all_packages  # Added for scanning system
    Package.joins(:origin_area, :destination_area)
           .where(origin_areas: { location_id: id })
           .or(Package.joins(:origin_area, :destination_area)
                     .where(destination_areas: { location_id: id }))
  end
  
  def package_volume  # Added for analytics
    {
      total_packages: all_packages.count,
      outgoing_packages: Package.joins(:origin_area).where(origin_areas: { location_id: id }).count,
      incoming_packages: Package.joins(:destination_area).where(destination_areas: { location_id: id }).count
    }
  end
  
  # Safe initials method that handles missing initials column
  def safe_initials
    return initials if respond_to?(:initials) && initials.present?
    generate_initials_from_name(name)
  end
  
  # Enhanced JSON serialization
  def as_json(options = {})
    result = super(options)
    
    if options[:include_stats]
      result.merge!(
        'areas_count' => areas_count,
        'agents_count' => agents_count,
        'riders_count' => riders_count,
        'warehouse_staff_count' => warehouse_staff_count,
        'total_staff_count' => total_staff_count,
        'can_be_deleted' => can_be_deleted?
      )
    end
    
    if options[:include_packages]
      result['package_volume'] = package_volume
    end
    
    result
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