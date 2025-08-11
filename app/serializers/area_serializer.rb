# app/serializers/area_serializer.rb
class AreaSerializer
  include ActiveModel::Serializers::JSON

  def initialize(area)
    @area = area
  end

  def as_json(options = {})
    {
      id: @area.id.to_s,
      name: @area.name,
      initials: @area.initials || generate_initials(@area.name),
      location_id: @area.location_id.to_s,
      location: location_data,
      created_at: @area.created_at&.iso8601,
      updated_at: @area.updated_at&.iso8601
    }
  end

  def self.serialize_collection(areas)
    areas.includes(:location).map { |area| new(area).as_json }
  end

  private

  def location_data
    return nil unless @area.location
    
    {
      id: @area.location.id.to_s,
      name: @area.location.name,
      initials: @area.location.initials || generate_initials(@area.location.name)
    }
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