# app/models/area.rb  
class Area < ApplicationRecord
  belongs_to :location
  has_many :agents, dependent: :restrict_with_error
  has_many :riders, dependent: :restrict_with_error  # Added for scanning system
  
  # Package associations
  has_many :origin_packages, class_name: 'Package', foreign_key: 'origin_area_id', dependent: :restrict_with_error
  has_many :destination_packages, class_name: 'Package', foreign_key: 'destination_area_id', dependent: :restrict_with_error
  
  # Validations
  validates :name, presence: true, uniqueness: { scope: :location_id }
  validates :initials, presence: true, uniqueness: true, 
            format: { with: /\A[A-Z]{2,3}\z/, message: "must be 2-3 uppercase letters" }
  
  # Callbacks
  before_validation :generate_initials, if: -> { initials.blank? && name.present? }
  before_validation :upcase_initials
  
  # Scopes
  scope :with_packages, -> { joins(:origin_packages).distinct }
  scope :active, -> { joins(:agents).where(agents: { active: true }).distinct }
  scope :with_active_riders, -> { joins(:riders).where(riders: { active: true }).distinct }  # Added
  scope :with_staff, -> { joins(:agents, :riders).distinct }  # Added

  # Instance methods for package management
  def package_count
    origin_packages.count + destination_packages.count
  end
  
  def active_agents_count
    agents.where(active: true).count
  rescue
    agents.count # Fallback if 'active' column doesn't exist
  end
  
  def active_riders_count  # Added for scanning system
    riders.where(active: true).count
  rescue
    riders.count
  end
  
  def total_staff_count  # Added for scanning system
    active_agents_count + active_riders_count
  end
  
  def all_packages
    Package.where(origin_area: self).or(Package.where(destination_area: self))
  end
  
  def can_be_deleted?
    package_count == 0 && agents.count == 0 && riders.count == 0  # Updated
  end

  def full_name
    "#{name}, #{location.name}"
  end

  # Route statistics
  def route_statistics
    {
      outgoing_routes: outgoing_route_stats,
      incoming_routes: incoming_route_stats,
      total_outgoing: origin_packages.count,
      total_incoming: destination_packages.count
    }
  end

  def outgoing_route_stats
    origin_packages.joins(:destination_area)
                  .group('destination_areas.name', 'destination_areas.id')
                  .count
                  .map { |(name, id), count| 
                    { 
                      destination: name, 
                      destination_id: id, 
                      package_count: count,
                      is_intra_area: id == self.id
                    }
                  }
  end

  def incoming_route_stats
    destination_packages.joins(:origin_area)
                       .group('origin_areas.name', 'origin_areas.id') 
                       .count
                       .map { |(name, id), count| 
                         { 
                           origin: name, 
                           origin_id: id, 
                           package_count: count,
                           is_intra_area: id == self.id
                         }
                       }
  end

  # Get next sequence number for packages from this area to destination area
  def next_package_sequence_to(destination_area)
    if self == destination_area
      # Intra-area shipment
      origin_packages.where(destination_area: destination_area).maximum(:route_sequence).to_i + 1
    else
      # Inter-area shipment
      origin_packages.where(destination_area: destination_area).maximum(:route_sequence).to_i + 1
    end
  end

  # Get popular routes from this area
  def popular_destinations(limit = 5)
    origin_packages.joins(:destination_area)
                  .where.not(destination_area_id: id) # Exclude intra-area
                  .group('destination_areas.name', 'destination_areas.id')
                  .order('count_all DESC')
                  .limit(limit)
                  .count
                  .map { |(name, id), count| { name: name, id: id, package_count: count } }
  end

  # Enhanced JSON serialization
  def as_json(options = {})
    result = super(options)
    
    if options[:include_stats]
      result.merge!(
        'package_count' => package_count,
        'active_agents_count' => active_agents_count,
        'active_riders_count' => active_riders_count,  # Added
        'total_staff_count' => total_staff_count,  # Added
        'can_be_deleted' => can_be_deleted?
      )
    end
    
    if options[:include_routes]
      result['route_statistics'] = route_statistics
      result['popular_destinations'] = popular_destinations
    end
    
    result
  end

  private

  def generate_initials
    # Extract first letters of significant words, excluding common words
    exclude_words = %w[the and or of in on at to from]
    
    words = name.downcase.split(/\s+/).reject { |word| exclude_words.include?(word) }
    
    if words.length >= 2
      # Take first letter of first two significant words
      self.initials = (words[0][0] + words[1][0]).upcase
    else
      # Take first 3 letters of the name
      self.initials = name.gsub(/[^A-Za-z]/, '')[0, 3].upcase
    end
    
    # Ensure uniqueness by adding number if needed
    counter = 1
    base_initials = initials
    while Area.exists?(initials: initials)
      self.initials = "#{base_initials}#{counter}"
      counter += 1
    end
  end

  def upcase_initials
    self.initials = initials&.upcase
  end
