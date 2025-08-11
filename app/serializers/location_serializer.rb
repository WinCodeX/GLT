class LocationSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :name, :created_at, :updated_at
  
  attribute :initials do |location|
    if location.respond_to?(:initials) && location.initials.present?
      location.initials
    elsif location.respond_to?(:safe_initials)
      location.safe_initials
    else
      generate_initials(location.name)
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