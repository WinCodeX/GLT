# app/serializers/package_serializer.rb
class PackageSerializer
  include ActiveModel::Serializers::JSON

  def initialize(package)
    @package = package
  end

  def as_json(options = {})
    # Minimal serialization for search results and listings
    if options[:minimal]
      return {
        id: @package.id.to_s,
        code: @package.code,
        tracking_code: @package.code,
        state: @package.state,
        state_display: @package.state.humanize,
        route_description: @package.route_description,
        created_at: @package.created_at&.iso8601
      }
    end

    result = {
      id: @package.id.to_s,
      code: @package.code,
      tracking_code: @package.code, # Alias for backward compatibility
      state: @package.state,
      state_display: @package.state.humanize,
      delivery_type: @package.delivery_type,
      cost: @package.cost,
      sender_name: @package.sender_name,
      sender_phone: @package.sender_phone,
      receiver_name: @package.receiver_name,
      receiver_phone: @package.receiver_phone,
      route_description: @package.route_description,
      is_intra_area: @package.intra_area_shipment?,
      is_paid: @package.paid?,
      is_trackable: @package.trackable?,
      can_be_cancelled: @package.can_be_cancelled?,
      tracking_url: safe_tracking_url,
      created_at: @package.created_at&.iso8601,
      updated_at: @package.updated_at&.iso8601
    }

    # Include areas if requested or loaded
    if options[:include_areas] || @package.association(:origin_area).loaded?
      result[:origin_area] = area_data(@package.origin_area)
      result[:destination_area] = area_data(@package.destination_area)
    end

    # Include agents if requested or loaded
    if options[:include_agents] || @package.association(:origin_agent).loaded?
      result[:origin_agent] = agent_data(@package.origin_agent)
      result[:destination_agent] = agent_data(@package.destination_agent)
    end

    # Include user if requested
    if options[:include_user] && @package.user
      result[:user] = {
        id: @package.user.id.to_s,
        name: safe_user_name
      }
    end

    # Include QR code if requested
    if options[:include_qr_code]
      qr_options = options[:qr_options] || {}
      result[:qr_code_base64] = safe_qr_code(qr_options)
    end

    result
  end

  def self.serialize_collection(packages, options = {})
    packages.map { |package| new(package).as_json(options) }
  end

  private

  def area_data(area)
    return nil unless area
    
    {
      id: area.id.to_s,
      name: area.name,
      initials: safe_initials(area),
      location_id: area.location_id&.to_s,
      location: location_data(area.location)
    }
  end

  def location_data(location)
    return nil unless location
    
    {
      id: location.id.to_s,
      name: location.name,
      initials: safe_initials(location)
    }
  end

  def agent_data(agent)
    return nil unless agent
    
    {
      id: agent.id.to_s,
      name: agent.name,
      phone: agent.phone,
      area_id: agent.area_id&.to_s
    }
  end

  def safe_initials(record)
    return '' unless record
    
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

  def safe_tracking_url
    @package.tracking_url
  rescue => e
    # Fallback URL generation
    Rails.logger.warn "Failed to generate tracking URL for package #{@package.id}: #{e.message}"
    "/track/#{@package.code}"
  end

  def safe_user_name
    @package.user.name
  rescue
    @package.user.email&.split('@')&.first || 'User'
  end

  def safe_qr_code(options = {})
    @package.qr_code_base64(options)
  rescue => e
    Rails.logger.warn "Failed to generate QR code for package #{@package.id}: #{e.message}"
    nil
  end
end