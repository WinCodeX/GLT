# app/serializers/agent_serializer.rb
class AgentSerializer
  include ActiveModel::Serializers::JSON

  def initialize(agent)
    @agent = agent
  end

  def as_json(options = {})
    {
      id: @agent.id.to_s,
      name: @agent.name,
      phone: @agent.phone,
      area_id: @agent.area_id.to_s,
      user_id: @agent.user_id&.to_s,
      active: @agent.respond_to?(:active?) ? @agent.active? : true,
      area: area_data,
      created_at: @agent.created_at&.iso8601,
      updated_at: @agent.updated_at&.iso8601
    }
  end

  def self.serialize_collection(agents)
    agents.includes(area: :location).map { |agent| new(agent).as_json }
  end

  private

  def area_data
    return nil unless @agent.area
    
    {
      id: @agent.area.id.to_s,
      name: @agent.area.name,
      initials: safe_initials(@agent.area),
      location_id: @agent.area.location_id.to_s,
      location: location_data
    }
  end

  def location_data
    return nil unless @agent.area&.location
    
    {
      id: @agent.area.location.id.to_s,
      name: @agent.area.location.name,
      initials: safe_initials(@agent.area.location)
    }
  end

  def safe_initials(record)
    # Try the initials attribute first, then generate from name
    if record.respond_to?(:initials) && record.initials.present?
      record.initials
    elsif record.respond_to?(:safe_initials)
      record.safe_initials
    else
      generate_initials(record.name)
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