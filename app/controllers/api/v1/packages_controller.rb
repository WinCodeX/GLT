# app/controllers/api/v1/packages_controller.rb
class Api::V1::PackagesController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_client_role, only: [:create]
  before_action :set_package_by_code, only: [:show, :update, :destroy]
  before_action :set_package_for_authenticated_user, only: [:update, :destroy]
  before_action :authorize_package_action, only: [:update, :destroy]

  def index
    @packages = current_user.accessible_packages
                            .includes(:origin_area, :destination_area, :origin_agent, :destination_agent,
                                     origin_area: :location, destination_area: :location)
                            .order(created_at: :desc)
                            .limit(50)

    render json: {
      success: true,
      data: @packages.map { |pkg| serialize_package_basic(pkg) },
      meta: {
        total_count: @packages.size,
        current_user_role: current_user.primary_role
      }
    }
  end

  def show
    render json: {
      success: true,
      data: serialize_package_full(@package)
    }
  end

  def create
    Rails.logger.info "🆕 Creating package: delivery_type=#{package_params[:delivery_type]}, destination_area_id=#{package_params[:destination_area_id]}, destination_agent_id=#{package_params[:destination_agent_id]}"
    
    @package = current_user.packages.build(package_params)
    
    # Set additional parameters safely without trying to assign to computed methods
    set_additional_package_parameters_safely

    # Calculate cost before saving to ensure proper validation
    begin
      @package.cost = calculate_package_cost(@package)
    rescue => e
      Rails.logger.error "Cost calculation failed: #{e.message}"
      @package.cost = 0 # Set default cost to avoid validation errors
    end

    # Wrap in transaction and handle callback errors gracefully
    Package.transaction do
      if @package.save
        # Generate QR codes after successful save
        begin
          @package.generate_qr_code_files if @package.respond_to?(:generate_qr_code_files)
        rescue => e
          Rails.logger.warn "QR code generation failed for package #{@package.code}: #{e.message}"
          # Don't fail the entire request if QR generation fails
        end

        render json: {
          success: true,
          data: serialize_package_full(@package),
          message: 'Package created successfully'
        }, status: :created
      else
        render json: {
          success: false,
          errors: @package.errors.full_messages,
          message: 'Failed to create package'
        }, status: :unprocessable_entity
      end
    end
  rescue => e
    Rails.logger.error "PackagesController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    
    render json: {
      success: false,
      message: 'An error occurred while creating the package',
      error: Rails.env.development? ? e.message : 'Internal server error'
    }, status: :internal_server_error
  end

  def update
    update_params = package_update_params

    if @package.update(update_params)
      render json: {
        success: true,
        data: serialize_package_full(@package),
        message: 'Package updated successfully'
      }
    else
      render json: {
        success: false,
        errors: @package.errors.full_messages,
        message: 'Failed to update package'
      }, status: :unprocessable_entity
    end
  rescue => e
    Rails.logger.error "PackagesController#update error: #{e.message}"
    render json: {
      success: false,
      message: 'An error occurred while updating the package'
    }, status: :internal_server_error
  end

  def destroy
    if @package.destroy
      render json: {
        success: true,
        message: 'Package deleted successfully'
      }
    else
      render json: {
        success: false,
        errors: @package.errors.full_messages,
        message: 'Failed to delete package'
      }, status: :unprocessable_entity
    end
  end

  # QR Code generation endpoint
  def qr_code
    qr_type = params[:type]&.to_sym || :organic
    qr_options = params[:options] || {}
    
    case qr_type
    when :thermal
      if @package.respond_to?(:thermal_qr_response)
        response_data = @package.thermal_qr_response(qr_options)
        render json: { success: true, data: response_data }
      else
        render json: { success: false, message: 'Thermal QR not supported' }
      end
    else
      if @package.respond_to?(:organic_qr_code_base64)
        qr_data = @package.organic_qr_code_base64(qr_options)
        render json: { success: true, qr_code_base64: qr_data, type: 'organic' }
      else
        render json: { success: false, message: 'QR code generation not available' }
      end
    end
  rescue => e
    render json: { success: false, message: "QR generation failed: #{e.message}" }
  end

  private

  def ensure_client_role
    unless current_user.client?
      render json: { 
        success: false, 
        message: 'Only clients can create packages' 
      }, status: :forbidden
    end
  end

  def authorize_package_action
    action_name = params[:action]
    
    case action_name
    when 'update'
      unless can_edit_package?(@package)
        render json: { 
          success: false, 
          message: 'You are not authorized to edit this package' 
        }, status: :forbidden
      end
    when 'destroy'
      unless can_delete_package?(@package)
        render json: { 
          success: false, 
          message: 'You are not authorized to delete this package' 
        }, status: :forbidden
      end
    end
  end

  # FIXED: Set additional package parameters safely without assigning to computed methods
  def set_additional_package_parameters_safely
    # Only set attributes that exist as database columns, not computed methods
    
    # Check if the package has these attributes before setting them
    safe_attributes = {}
    
    # Payment and delivery details (only if columns exist)
    if @package.respond_to?(:payment_method=) && params.dig(:package, :payment_method).present?
      safe_attributes[:payment_method] = params.dig(:package, :payment_method)
    end
    
    if @package.respond_to?(:special_instructions=) && params.dig(:package, :special_instructions).present?
      safe_attributes[:special_instructions] = params.dig(:package, :special_instructions)
    end
    
    if @package.respond_to?(:special_handling=)
      safe_attributes[:special_handling] = params.dig(:package, :special_handling) || @package.fragile?
    end
    
    if @package.respond_to?(:requires_payment_advance=)
      safe_attributes[:requires_payment_advance] = params.dig(:package, :requires_payment_advance) || false
    end
    
    # Collection and shop details (only if columns exist)
    if @package.respond_to?(:shop_name=) && params.dig(:package, :shop_name).present?
      safe_attributes[:shop_name] = params.dig(:package, :shop_name)
    end
    
    if @package.respond_to?(:shop_contact=) && params.dig(:package, :shop_contact).present?
      safe_attributes[:shop_contact] = params.dig(:package, :shop_contact)
    end
    
    if @package.respond_to?(:collection_address=) && params.dig(:package, :collection_address).present?
      safe_attributes[:collection_address] = params.dig(:package, :collection_address)
    end
    
    if @package.respond_to?(:items_to_collect=) && params.dig(:package, :items_to_collect).present?
      safe_attributes[:items_to_collect] = params.dig(:package, :items_to_collect)
    end

    # Item value and description (only if columns exist)
    if @package.respond_to?(:item_value=) && params.dig(:package, :item_value).present?
      safe_attributes[:item_value] = params.dig(:package, :item_value)
    end
    
    if @package.respond_to?(:item_description=) && params.dig(:package, :item_description).present?
      safe_attributes[:item_description] = params.dig(:package, :item_description)
    end

    # Payment deadline (only if column exists)
    if @package.respond_to?(:payment_deadline=) && params.dig(:package, :payment_deadline).present?
      safe_attributes[:payment_deadline] = params.dig(:package, :payment_deadline)
    end

    # Scheduling (only if column exists)
    if @package.respond_to?(:collection_scheduled_at=) && params.dig(:package, :collection_scheduled_at).present?
      safe_attributes[:collection_scheduled_at] = params.dig(:package, :collection_scheduled_at)
    end

    # Coordinates for mapping (only if columns exist)
    if @package.respond_to?(:pickup_latitude=) && params.dig(:package, :pickup_latitude).present?
      safe_attributes[:pickup_latitude] = params.dig(:package, :pickup_latitude)
    end
    
    if @package.respond_to?(:pickup_longitude=) && params.dig(:package, :pickup_longitude).present?
      safe_attributes[:pickup_longitude] = params.dig(:package, :pickup_longitude)
    end
    
    if @package.respond_to?(:delivery_latitude=) && params.dig(:package, :delivery_latitude).present?
      safe_attributes[:delivery_latitude] = params.dig(:package, :delivery_latitude)
    end
    
    if @package.respond_to?(:delivery_longitude=) && params.dig(:package, :delivery_longitude).present?
      safe_attributes[:delivery_longitude] = params.dig(:package, :delivery_longitude)
    end

    # Collection type (only if column exists)
    if @package.respond_to?(:collection_type=) && params.dig(:package, :collection_type).present?
      safe_attributes[:collection_type] = params.dig(:package, :collection_type)
    end

    # Apply all safe attributes at once
    @package.assign_attributes(safe_attributes) unless safe_attributes.empty?
    
    Rails.logger.info "Set safe attributes: #{safe_attributes.keys.join(', ')}" unless safe_attributes.empty?
  end

  def calculate_package_cost(package)
    return 0 unless package.origin_area_id && package.destination_area_id

    # Try to find existing price
    price = Price.find_by(
      origin_area_id: package.origin_area_id,
      destination_area_id: package.destination_area_id,
      origin_agent_id: package.origin_agent_id,
      destination_agent_id: package.destination_agent_id,
      delivery_type: package.delivery_type
    )

    if price
      base_cost = price.cost
    else
      # Calculate default cost based on areas
      base_cost = calculate_default_cost(package)
    end

    # Add fragile handling surcharge if applicable (use the computed method)
    if package.fragile?
      fragile_surcharge = (base_cost * 0.15).round # 15% surcharge for fragile items
      base_cost += fragile_surcharge
    end

    base_cost
  end

  def calculate_default_cost(package)
    # Basic cost calculation based on area types
    if package.origin_area_id == package.destination_area_id
      200 # Intra-area delivery
    else
      500 # Inter-area delivery
    end
  end

  # Serialization methods
  def serialize_package_basic(package)
    {
      'id' => package.id.to_s,
      'code' => package.code,
      'sender_name' => package.sender_name,
      'receiver_name' => package.receiver_name,
      'delivery_type' => package.delivery_type,
      'state' => package.state,
      'cost' => package.cost,
      'created_at' => package.created_at,
      'origin_area' => serialize_area(package.origin_area),
      'destination_area' => serialize_area(package.destination_area),
      'is_fragile' => package.fragile?
    }
  end

  def serialize_package_full(package)
    base_data = serialize_package_basic(package)
    
    base_data.merge({
      'sender_phone' => package.sender_phone,
      'receiver_phone' => package.receiver_phone,
      'delivery_location' => package.delivery_location,
      'special_instructions' => package.respond_to?(:special_instructions) ? package.special_instructions : nil,
      'priority_level' => package.priority_level, # Use computed method
      'handling_instructions' => package.handling_instructions, # Use computed method
      'payment_method' => package.respond_to?(:payment_method) ? package.payment_method : nil,
      'special_handling' => package.respond_to?(:special_handling) ? package.special_handling : package.fragile?,
      'requires_payment_advance' => package.respond_to?(:requires_payment_advance) ? package.requires_payment_advance : false,
      'origin_agent' => serialize_agent(package.origin_agent),
      'destination_agent' => serialize_agent(package.destination_agent),
      'user' => serialize_user_basic(package.user),
      'tracking_url' => package.respond_to?(:tracking_url) ? package.tracking_url : nil,
      'updated_at' => package.updated_at
    })
  end

  def serialize_area(area)
    return nil unless area
    
    {
      'id' => area.id.to_s,
      'name' => area.name,
      'location' => area.location ? serialize_location(area.location) : nil
    }
  end

  def serialize_location(location)
    return nil unless location
    
    {
      'id' => location.id.to_s,
      'name' => location.name
    }
  end

  def serialize_agent(agent)
    return nil unless agent
    
    {
      'id' => agent.id.to_s,
      'name' => agent.name,
      'phone' => agent.phone,
      'area' => agent.respond_to?(:area) ? serialize_area(agent.area) : nil
    }
  end

  def serialize_user_basic(user)
    return nil unless user
    
    name = if user.respond_to?(:name) && user.name.present?
      user.name
    elsif user.respond_to?(:first_name) && user.respond_to?(:last_name)
      "#{user.first_name} #{user.last_name}".strip
    elsif user.respond_to?(:first_name) && user.first_name.present?
      user.first_name
    elsif user.respond_to?(:last_name) && user.last_name.present?
      user.last_name
    else
      user.email
    end
    
    {
      'id' => user.id.to_s,
      'name' => name,
      'email' => user.email,
      'role' => user.primary_role
    }
  end

  def set_package_by_code
    @package = Package.includes(:origin_area, :destination_area, :origin_agent, :destination_agent,
                               origin_area: :location, destination_area: :location)
                      .find_by!(code: params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { 
      success: false, 
      message: 'Package not found' 
    }, status: :not_found
  end

  def set_package_for_authenticated_user
    @package = current_user.accessible_packages
                           .includes(:origin_area, :destination_area, :origin_agent, :destination_agent,
                                    origin_area: :location, destination_area: :location)
                           .find_by!(code: params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { 
      success: false, 
      message: 'Package not found or access denied' 
    }, status: :not_found
  end

  def can_edit_package?(package)
    case current_user.primary_role
    when 'client'
      package.user == current_user && ['pending_unpaid', 'pending'].include?(package.state)
    when 'admin'
      true
    when 'agent', 'rider', 'warehouse'
      true
    else
      false
    end
  end

  def can_delete_package?(package)
    case current_user.primary_role
    when 'client'
      package.user == current_user
    when 'admin'
      true
    else
      false
    end
  end

  # FIXED: Expanded strong parameters to accept all legitimate frontend fields
  def package_params
    # Base required parameters
    base_params = [
      :sender_name, :sender_phone, :receiver_name, :receiver_phone,
      :origin_area_id, :destination_area_id, :origin_agent_id, :destination_agent_id,
      :delivery_type, :delivery_location
    ]
    
    # Extended parameters that the frontend legitimately sends
    extended_params = [
      :sender_email, :receiver_email, :business_name, :special_instructions,
      :shop_name, :shop_contact, :collection_address, :items_to_collect,
      :item_value, :item_description, :payment_method, :special_handling,
      :requires_payment_advance, :collection_type, :pickup_latitude,
      :pickup_longitude, :delivery_latitude, :delivery_longitude,
      :payment_deadline, :collection_scheduled_at
    ]
    
    # Only include parameters for columns that actually exist in the database
    all_params = base_params + extended_params.select do |field|
      Package.column_names.include?(field.to_s)
    end
    
    Rails.logger.info "Permitting parameters: #{all_params.join(', ')}"
    
    params.require(:package).permit(*all_params)
  end

  def package_update_params
    base_params = [
      :sender_name, :sender_phone, :receiver_name, :receiver_phone, 
      :destination_area_id, :destination_agent_id, :delivery_type, :state,
      :origin_agent_id, :delivery_location
    ]
    
    # Add extended update parameters
    extended_params = [
      :sender_email, :receiver_email, :business_name, :special_instructions,
      :payment_method, :special_handling, :requires_payment_advance
    ]
    
    all_params = base_params + extended_params.select do |field|
      Package.column_names.include?(field.to_s)
    end
    
    permitted_params = []
    
    case current_user.primary_role
    when 'client'
      if ['pending_unpaid', 'pending'].include?(@package.state)
        permitted_params = [:sender_name, :sender_phone, :receiver_name, :receiver_phone, 
                           :destination_area_id, :destination_agent_id, :delivery_location,
                           :sender_email, :receiver_email, :business_name, :special_instructions].select do |field|
          all_params.include?(field)
        end
      end
    when 'admin'
      permitted_params = all_params
    when 'agent', 'rider', 'warehouse'
      permitted_params = [:state, :destination_area_id, :destination_agent_id, 
                         :delivery_location, :special_instructions].select do |field|
        all_params.include?(field)
      end
    end
    
    params.require(:package).permit(*permitted_params)
  end
end