class AgentSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :name, :phone, :area_id, :user_id, :created_at, :updated_at
  belongs_to :area, serializer: AreaSerializer
  
  attribute :active do |agent|
    agent.respond_to?(:active?) ? agent.active? : true
  end
end

