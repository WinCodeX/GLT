class PriceSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :cost, :delivery_type, :created_at, :updated_at
  
  belongs_to :origin_area, serializer: AreaSerializer
  belongs_to :destination_area, serializer: AreaSerializer
  belongs_to :origin_agent, serializer: AgentSerializer
  belongs_to :destination_agent, serializer: AgentSerializer
  
  attribute :route_description do |price|
    price.route_description
  end
end