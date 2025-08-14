# app/models/area.rb  
class Area < ApplicationRecord
  belongs_to :location
  has_many :agents, dependent: :restrict_with_error
  has_many :riders, dependent: :restrict_with_error
  
  # Package associations
  has_many :origin_packages, class_name: 'Package', foreign_key: 'origin_area_id', dependent: :restrict_with_error
  has_many :destination_packages, class_name: 'Package', foreign_key: 'destination_area_id', dependent: :restrict_with_error
  
  # Validations
  validates :name, presence: true, uniqueness: { scope: :location_id }
  validates :initials, presence: true, uniqueness: true, 
            format: { with: /\A[A-Z]{2,4}\z/, message: "must be 2-4 uppercase letters" }, # Allow up to 4 characters
            length: { maximum: 4 }
  
  # Callbacks
  before_validation :generate_initials, if: -> { initials.blank? && name.present? }
  before_validation :upcase_initials
  
  # Scopes - Fixed to handle LEFT JOINs properly and avoid duplicates
  scope :with_packages, -> { 
    where(
      id: Package.select(:origin_area_id)
        .union(Package.select(:destination_area_id))
        .where.not(origin_area_id: nil, destination_area_id: nil)
    ).distinct
  }
  
  scope :active, -> { 
    joins(:agents).where(agents: { active: true }).distinct 
  }
  
  scope :with_active_riders, -> { 
    joins(:riders).where(riders: { active: true }).distinct 
  }
  
  scope :with_staff, -> { 
    where(
      id: Agent.select(:area_id).where(active: true)
        .union(Rider.select(:area_id).where(active: true))
    ).distinct
  }

  # Instance methods for package management - Fixed with better error handling
  def package_count
    @package_count ||= Package.where(origin_area: self)
                             .or(Package.where(destination_area: self))
                             .count
  end
  
  def active_agents_count
    @active_agents_count ||= begin
      if agents.column_names.include?('active')
        agents.where(active: true).count
      else
        agents.count
      end
    end
  end
  
  def active_riders_count
    @active_riders_count ||= begin
      if riders.column_names.include?('active')
        riders.where(active: true).count
      else
        riders.count
      end
    end
  end
  
  def total_staff_count
    active_agents_count + active_riders_count
  end
  
  def all_packages
    @all_packages ||= Package.where(origin_area: self).or(Package.where(destination_area: self))
  end
  
  def can_be_deleted?
    package_count == 0 && agents.count == 0 && riders.count == 0
  end

  def full_name
    "#{name}, #{location.name}"
  end

  # Route statistics - Optimized queries
  def route_statistics
    Rails.cache.fetch("area_#{id}_route_stats", expires_in: 1.hour) do
      {
        outgoing_routes: outgoing_route_stats,
        incoming_routes: incoming_route_stats,
        total_outgoing: origin_packages.count,
        total_incoming: destination_packages.count
      }
    end
  end

  def outgoing_route_stats
    origin_packages.joins(:destination_area)
                  .group('areas.name', 'areas.id')
                  .count
                  .map { |(name, dest_id), count| 
                    { 
                      destination: name, 
                      destination_id: dest_id, 
                      package_count: count,
                      is_intra_area: dest_id == id
                    }
                  }
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.error "Error in outgoing_route_stats for area #{id}: #{e.message}"
    []
  end

  def incoming_route_stats
    destination_packages.joins(:origin_area)
                       .group('areas.name', 'areas.id') 
                       .count
                       .map { |(name, orig_id), count| 
                         { 
                           origin: name, 
                           origin_id: orig_id, 
                           package_count: count,
                           is_intra_area: orig_id == id
                         }
                       }
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.error "Error in incoming_route_stats for area #{id}: #{e.message}"
    []
  end

  # Get next sequence number for packages from this area to destination area
  def next_package_sequence_to(destination_area)
    return 1 if destination_area.nil?
    
    max_sequence = origin_packages.where(destination_area: destination_area)
                                 .maximum(:route_sequence)
    
    (max_sequence || 0) + 1
  rescue ActiveRecord::StatementInvalid
    1
  end

  # Get popular routes from this area - Fixed query
  def popular_destinations(limit = 5)
    return [] if limit <= 0
    
    Rails.cache.fetch("area_#{id}_popular_destinations_#{limit}", expires_in: 2.hours) do
      origin_packages.joins(:destination_area)
                    .where.not(destination_area_id: id) # Exclude intra-area
                    .group('areas.name', 'areas.id')
                    .order('count_all DESC')
                    .limit(limit)
                    .count
                    .map { |(name, dest_id), count| 
                      { 
                        name: name, 
                        id: dest_id, 
                        package_count: count 
                      } 
                    }
    end
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.error "Error in popular_destinations for area #{id}: #{e.message}"
    []
  end

  # Performance metrics for scanning system
  def scanning_performance(date_range = 1.week.ago..Time.current)
    return {} unless defined?(PackageTrackingEvent)
    
    {
      total_scans: PackageTrackingEvent.joins(package: :origin_area)
                                      .where(packages: { origin_area: self })
                                      .where(created_at: date_range)
                                      .count,
      packages_processed: all_packages.joins(:tracking_events)
                                     .where(package_tracking_events: { created_at: date_range })
                                     .distinct
                                     .count,
      average_processing_time: calculate_average_processing_time(date_range)
    }
  rescue StandardError => e
    Rails.logger.error "Error calculating scanning performance for area #{id}: #{e.message}"
    {}
  end

  # Enhanced JSON serialization with better performance
  def as_json(options = {})
    result = super(options.except(:include_stats, :include_routes, :include_location))
    
    # Always include location info unless explicitly excluded
    unless options[:exclude_location]
      result['location'] = {
        'id' => location.id,
        'name' => location.name
      }
    end
    
    if options[:include_stats]
      result.merge!(
        'package_count' => package_count,
        'active_agents_count' => active_agents_count,
        'active_riders_count' => active_riders_count,
        'total_staff_count' => total_staff_count,
        'can_be_deleted' => can_be_deleted?
      )
    end
    
    if options[:include_routes]
      result['route_statistics'] = route_statistics
      result['popular_destinations'] = popular_destinations(options[:destination_limit] || 5)
    end
    
    if options[:include_performance] && options[:date_range]
      result['scanning_performance'] = scanning_performance(options[:date_range])
    end
    
    result
  end

  # Clear cached data when area is updated
  def clear_cache!
    Rails.cache.delete_matched("area_#{id}_*")
  end

  private

  def generate_initials
    # Extract first letters of significant words, excluding common words
    exclude_words = %w[the and or of in on at to from with by for]
    
    words = name.downcase.split(/\s+/).reject { |word| exclude_words.include?(word) }
    
    if words.length >= 2
      # Take first letter of first two significant words
      self.initials = (words[0][0] + words[1][0]).upcase
    elsif words.length == 1 && words[0].length >= 3
      # Take first 3 letters of the single word
      self.initials = words[0][0, 3].upcase
    else
      # Fallback: take first letters available
      self.initials = name.gsub(/[^A-Za-z]/, '')[0, 3].upcase
    end
    
    # Ensure we have at least 2 characters
    if initials.length < 2
      self.initials = initials.ljust(2, 'X')
    end
    
    # Ensure uniqueness by adding number if needed (but limit to prevent infinite loop)
    counter = 1
    base_initials = initials
    max_attempts = 99
    
    while Area.exists?(initials: initials) && counter <= max_attempts
      if base_initials.length >= 3
        # If base is 3+ chars, replace last char with number
        self.initials = "#{base_initials[0, 2]}#{counter}"
      else
        # If base is 2 chars, append number
        self.initials = "#{base_initials}#{counter}"
      end
      counter += 1
    end
    
    # If we couldn't generate unique initials, use a random approach
    if counter > max_attempts
      self.initials = "#{('A'..'Z').to_a.sample(2).join}#{rand(10..99)}"
    end
    
    # Final length check
    self.initials = initials[0, 4] if initials.length > 4
  end

  def upcase_initials
    self.initials = initials&.upcase
  end

  def calculate_average_processing_time(date_range)
    return 0 unless defined?(PackageTrackingEvent)
    
    # Calculate average time between submission and first scan
    processed_packages = all_packages.joins(:tracking_events)
                                   .where(package_tracking_events: { created_at: date_range })
                                   .where.not(submitted_at: nil)
                                   .distinct
    
    return 0 if processed_packages.empty?
    
    total_time = processed_packages.sum do |package|
      first_scan = package.tracking_events
                         .where(created_at: date_range)
                         .order(:created_at)
                         .first
      
      if first_scan && package.submitted_at
        (first_scan.created_at - package.submitted_at).to_i
      else
        0
      end
    end
    
    total_time / processed_packages.count
  rescue StandardError
    0
  end

  # Callback to clear cache when model is updated
  after_update :clear_cache!
  after_destroy :clear_cache!
end