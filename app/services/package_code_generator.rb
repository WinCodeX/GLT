# 3. Package Code Generator Service
# app/services/package_code_generator.rb
class PackageCodeGenerator
  attr_reader :package
  
  def initialize(package)
    @package = package
  end
  
  def generate
    return package.code if package.code.present?
    
    origin_initials = package.origin_area&.initials
    destination_initials = package.destination_area&.initials
    
    return generate_fallback_code unless origin_initials
    
    sequence = calculate_sequence_number
    
    if intra_area_shipment?
      # Format: NRB-001
      "#{origin_initials}-#{format_sequence(sequence)}"
    else
      # Format: NRB-001-KSM
      dest_suffix = destination_initials || 'UNK'
      "#{origin_initials}-#{format_sequence(sequence)}-#{dest_suffix}"
    end
  end
  
  private
  
  def intra_area_shipment?
    package.origin_area_id == package.destination_area_id
  end
  
  def calculate_sequence_number
    # Thread-safe sequence generation
    Package.transaction do
      if intra_area_shipment?
        # Count packages within same area
        max_sequence = Package.where(
          origin_area_id: package.origin_area_id,
          destination_area_id: package.destination_area_id
        ).lock.maximum(:route_sequence).to_i
      else
        # Count packages between specific areas
        max_sequence = Package.where(
          origin_area_id: package.origin_area_id,
          destination_area_id: package.destination_area_id
        ).lock.maximum(:route_sequence).to_i
      end
      
      next_sequence = max_sequence + 1
      package.route_sequence = next_sequence
      next_sequence
    end
  end
  
  def format_sequence(number)
    number.to_s.rjust(3, '0')
  end
  
  def generate_fallback_code
    # Fallback if areas don't have initials
    "PKG-#{SecureRandom.hex(4).upcase}"
  end
end