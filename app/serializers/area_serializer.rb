class AreaSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :name, :location_id, :created_at, :updated_at
  belongs_to :location, serializer: LocationSerializer
  
  attribute :initials do |area|
    if area.respond_to?(:initials) && area.initials.present?
      area.initials
    else
      generate_initials(area.name)
    end
  end
  
  private
  
  def self.generate_initials(name)
    return '' if name.blank?
    
    words = name.split(' ')
    if words.length >= 2
      words.first(2).map(&:first).join.upcase
    else
      name.first(3).upcase
    end
  end
end