class AgentSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :name, :phone, :area_id, :user_id, :created_at, :updated_at
  belongs_to :area, serializer: AreaSerializer
  
  attribute :active do |agent|
    agent.respond_to?(:active?) ? agent.active? : true
  end
end

# app/serializers/package_serializer.rb
class PackageSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :code, :state, :delivery_type, :cost, :sender_name, :sender_phone, 
             :receiver_name, :receiver_phone, :created_at, :updated_at
  
  belongs_to :origin_area, serializer: AreaSerializer
  belongs_to :destination_area, serializer: AreaSerializer
  belongs_to :origin_agent, serializer: AgentSerializer
  belongs_to :destination_agent, serializer: AgentSerializer
  belongs_to :user, serializer: UserSerializer
  
  attribute :tracking_code do |package|
    package.code
  end
  
  attribute :state_display do |package|
    package.state.humanize
  end
  
  attribute :route_description do |package|
    package.route_description
  end
  
  attribute :is_intra_area do |package|
    package.intra_area_shipment?
  end
  
  attribute :is_paid do |package|
    package.paid?
  end
  
  attribute :is_trackable do |package|
    package.trackable?
  end
  
  attribute :can_be_cancelled do |package|
    package.can_be_cancelled?
  end
  
  attribute :tracking_url do |package|
    begin
      package.tracking_url
    rescue => e
      Rails.logger.warn "Failed to generate tracking URL for package #{package.id}: #{e.message}"
      "/track/#{package.code}"
    end
  end
  
  # Conditional QR code attribute
  attribute :qr_code_base64, if: Proc.new { |record, params|
    params && params[:include_qr_code]
  } do |package, params|
    begin
      qr_options = params[:qr_options] || {}
      package.qr_code_base64(qr_options)
    rescue => e
      Rails.logger.warn "Failed to generate QR code for package #{package.id}: #{e.message}"
      nil
    end
  end
end
