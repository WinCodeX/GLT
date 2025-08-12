# app/services/package_code_generator.rb
class PackageCodeGenerator
  attr_reader :package
  
  def initialize(package)
    @package = package
  end
  
  def generate
    return package.code if package.code.present?
    
    # Get location initials - handle case where initials attribute might not exist
    origin_location_initials = get_location_initials(package.origin_area&.location)
    destination_location_initials = get_location_initials(package.destination_area&.location)
    
    return generate_fallback_code unless origin_location_initials
    
    sequence = calculate_sequence_number
    
    if intra_location_shipment?
      # Format: NRB-001 (same location, like CBD to Kasarani within Nairobi)
      "#{origin_location_initials}-#{format_sequence(sequence)}"
    else
      # Format: NRB-001-KSM (different locations, like Nairobi to Kisumu)
      dest_suffix = destination_location_initials || 'UNK'
      "#{origin_location_initials}-#{format_sequence(sequence)}-#{dest_suffix}"
    end
  end
  
  private
  
  def intra_location_shipment?
    # Check if both areas belong to the same location
    return false unless package.origin_area&.location && package.destination_area&.location
    package.origin_area.location.id == package.destination_area.location.id
  end
  
  def calculate_sequence_number
    # Thread-safe sequence generation based on location pairs
    Package.transaction do
      origin_location_id = package.origin_area&.location&.id
      destination_location_id = package.destination_area&.location&.id
      
      return fallback_sequence_calculation unless origin_location_id
      
      if intra_location_shipment?
        # Count packages within same location (all area combinations within the location)
        max_sequence = packages_for_intra_location_query(origin_location_id)
                        .maximum(:route_sequence).to_i
      else
        # Count packages between specific location pairs
        max_sequence = packages_for_inter_location_query(origin_location_id, destination_location_id)
                        .maximum(:route_sequence).to_i
      end
      
      next_sequence = max_sequence + 1
      package.route_sequence = next_sequence
      next_sequence
    end
  rescue => e
    Rails.logger.error "Sequence calculation failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    fallback_sequence_calculation
  end

  def packages_for_intra_location_query(location_id)
    # Get all area IDs for this location
    area_ids = Area.where(location_id: location_id).pluck(:id)
    
    # Find packages where both origin and destination are within the same location
    Package.where(
      origin_area_id: area_ids,
      destination_area_id: area_ids
    )
  end

  def packages_for_inter_location_query(origin_location_id, destination_location_id)
    # Get area IDs for both locations
    origin_area_ids = Area.where(location_id: origin_location_id).pluck(:id)
    destination_area_ids = Area.where(location_id: destination_location_id).pluck(:id)
    
    # Find packages between these specific location pairs
    Package.where(
      origin_area_id: origin_area_ids,
      destination_area_id: destination_area_ids
    )
  end
  
  def get_location_initials(location)
    return nil unless location
    
    # Try different attributes that might contain initials
    if location.respond_to?(:initials) && location.initials.present?
      location.initials.upcase
    elsif location.respond_to?(:code) && location.code.present?
      location.code.upcase[0..2]
    elsif location.respond_to?(:abbreviation) && location.abbreviation.present?
      location.abbreviation.upcase
    elsif location.name.present?
      # Generate initials from name (e.g., "Nairobi" -> "NRB", "Kisumu" -> "KSM")
      generate_initials_from_name(location.name)
    else
      'UNK'
    end
  end

  def generate_initials_from_name(name)
    # Remove common words and generate 3-letter code
    cleaned_name = name.upcase.gsub(/\b(CITY|TOWN|COUNTY|AREA)\b/, '').strip
    
    # If single word, take first 3 characters
    if cleaned_name.split.length == 1
      cleaned_name[0..2].ljust(3, 'X')
    else
      # Multiple words: take first letter of each word (max 3)
      initials = cleaned_name.split.map(&:first).join[0..2]
      initials.ljust(3, 'X')
    end
  end

  def fallback_sequence_calculation
    begin
      # Simple time-based sequence as ultimate fallback
      time_component = Time.current.strftime('%H%M').to_i
      random_component = rand(1..99)
      
      sequence = (time_component + random_component) % 999
      sequence = 1 if sequence == 0
      
      package.route_sequence = sequence
      sequence
    rescue => e
      Rails.logger.error "Fallback sequence calculation failed: #{e.message}"
      # Absolute final fallback
      package.route_sequence = 1
      1
    end
  end
  
  def format_sequence(number)
    number.to_s.rjust(3, '0')
  end
  
  def generate_fallback_code
    # Fallback if locations don't have initials
    "PKG-#{SecureRandom.hex(4).upcase}-#{Time.current.strftime('%m%d')}"
  end
end