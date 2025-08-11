# app/serializers/location_serializer.rb
class LocationSerializer
  include ActiveModel::Serializers::JSON

  def initialize(location)
    @location = location
  end

  def as_json(options = {})
    {
      id: @location.id.to_s,
      name: @location.name,
      initials: safe_initials(@location),
      created_at: @location.created_at&.iso8601,
      updated_at: @location.updated_at&.iso8601
    }
  end

  def self.serialize_collection(locations)
    locations.map { |location| new(location).as_json }
  end

  private

  def safe_initials(location)
    # Try the initials attribute first, then generate from name
    if location.respond_to?(:initials) && location.initials.present?
      location.initials
    elsif location.respond_to?(:safe_initials)
      location.safe_initials
    else
      generate_initials(location.name)
    end
  end

  def generate_initials(name)
    return '' if name.blank?
    
    words = name.split(' ')
    if words.length >= 2
      words.first(2).map(&:first).join.upcase
    else
      name.first(3).upcase
    end
  end
end