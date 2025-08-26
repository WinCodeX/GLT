# app/controllers/api/v1/packages_controller.rb - Fixed for enhanced delivery type handling
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
        current_user_role: current_user.primary_role,
        delivery_types_supported: Package.delivery_types.keys
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
    delivery_type = package_params[:delivery_type] || 'doorstep'
    Rails.logger.info "🆕 Creating #{delivery_type} package with params: #{package_params.except(:special_instructions).to_json}"
    
    # Build package with core parameters first
    @package = current_user.packages.build(package_params)
    
    # FIXED: Ensure all required fields are set before validation
    prepare_package_for_creation
    
    # Set additional parameters safely
    set_additional_package_parameters_safely

    Rails.logger.info "🔧 Package prepared for creation: delivery_type=#{@package.delivery_type}, state=#{@package.state}, code=#{@package.code&.present? ? 'SET' : 'PENDING'}"

    # Wrap in transaction and handle all creation steps
    Package.transaction do
      if @package.save
        Rails.logger.info "✅ Package created successfully: #{@package.code} (ID: #{@package.id})"
        
        # Generate QR codes after successful save (non-blocking)
        begin
          @package.generate_qr_code_files if @package.respond_to?(:generate_qr_code_files)
        rescue => e
          Rails.logger.warn "QR code generation failed for package #{@package.code}: #{e.message}"
          # Don't fail the entire request if QR generation fails
        end

        render json: {
          success: true,
          data: serialize_package_full(@package),
          message: "#{@package.delivery_type.humanize} package created successfully"
        }, status: :created
      else
        Rails.logger.error "❌ Package creation failed: #{@package.errors.full_messages.join(', ')}"
        render json: {
          success: false,
          errors: @package.errors.full_messages,
          message: 'Failed to create package',
          debug_info: Rails.env.development? ? {
            delivery_type: @package.delivery_type,
            state: @package.state,
            code: @package.code,
            cost: @package.cost,
            route_sequence: @package.route_sequence
          } : nil
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

  # New endpoint to get delivery type information
  def delivery_types
    render json: {
      success: true,
      data: PackageCodeGenerator.delivery_type_info,
      supported_types: Package.delivery_types.keys
    }
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

  # FIXED: Prepare package for creation with proper defaults and validation
  def prepare_package_for_creation
    # The model callbacks will handle most of this, but we can do some pre-validation here
    
    # Ensure delivery type is valid
    unless Package.delivery_types.key?(@package.delivery_type)
      @package.delivery_type = 'doorstep' # Default fallback
      Rails.logger.warn "Invalid delivery type provided, defaulting to doorstep"
    end
    
    # For packages without proper area setup, we might need to set defaults
    # This is handled by the model callbacks, but we log for debugging
    Rails.logger.info "📋 Package preparation: delivery_type=#{@package.delivery_type}"
    
    # Handle special delivery type requirements
    case @package.delivery_type
    when 'fragile'
      Rails.logger.info "⚠️ Preparing fragile package with special handling requirements"
    when 'collection'
      Rails.logger.info "📦 Preparing collection package with collection service setup"
    when 'express'
      Rails.logger.info "⚡ Preparing express package with priority handling"
    end
  end

  # FIXED: Set additional package parameters safely without assigning to computed methods
  def set_additional_package_parameters_safely
    # Only set attributes that exist as database columns, not computed methods
    safe_attributes = {}
    
    # Collection-specific attributes for collection delivery type
    if @package.collection? || params.dig(:package, :shop_name).present?
      collection_attributes = [
        :shop_name, :shop_contact, :collection_address, :items_to_collect,
        :item_value, :item_description, :collection_type
      ]
      
      collection_attributes.each do |attr|
        if @package.respond_to?("#{attr}=") && params.dig(:package, attr).present?
          safe_attributes[attr] = params.dig(:package, attr)
        end
      end
    end
    
    # General package attributes
    general_attributes = [
      :payment_method, :special_instructions, :special_handling,
      :requires_payment_advance, :pickup_latitude, :pickup_longitude,
      :delivery_latitude, :delivery_longitude, :payment_deadline,
      :collection_scheduled_at
    ]
    
    general_attributes.each do |attr|
      if @package.respond_to?("#{attr}=") && params.dig(:package, attr).present?
        safe_attributes[attr] = params.dig(:package, attr)
      end
    end
    
    # Set special handling to true for fragile packages if not explicitly provided
    if @package.fragile? && !safe_attributes.key?(:special_handling)
      safe_attributes[:special_handling] = true
    end
    
    # Set collection type for collection packages if not explicitly provided
    if @package.collection? && !safe_attributes.key?(:collection_type)
      safe_attributes[:collection_type] = 'shop_pickup'
    end

    # Apply all safe attributes at once
    @package.assign_attributes(safe_attributes) unless safe_attributes.empty?
    
    Rails.logger.info "🔧 Set safe attributes: #{safe_attributes.keys.join(', ')}" unless safe_attributes.empty?
  end

  # Serialization methods with enhanced delivery type information
  def serialize_package_basic(package)
    {
      'id' => package.id.to_s,
      'code' => package.code,
      'sender_name' => package.sender_name,
      'receiver_name' => package.receiver_name,
      'delivery_type' => package.delivery_type,
      'delivery_type_display' => package.delivery_type_display,
      'state' => package.state,
      'cost' => package.cost,
      'priority_level' => package.priority_level,
      'created_at' => package.created_at,
      'origin_area' => serialize_area(package.origin_area),
      'destination_area' => serialize_area(package.destination_area),
      'is_fragile' => package.fragile?,
      'is_collection' => package.collection?,
      'requires_special_handling' => package.requires_special_handling?
    }
  end

  def serialize_package_full(package)
    base_data = serialize_package_basic(package)
    
    enhanced_data = {
      'sender_phone' => package.sender_phone,
      'receiver_phone' => package.receiver_phone,
      'delivery_location' => package.delivery_location,
      'special_instructions' => package.respond_to?(:special_instructions) ? package.special_instructions : nil,
      'handling_instructions' => package.handling_instructions, # Use computed method
      'payment_method' => package.respond_to?(:payment_method) ? package.payment_method : nil,
      'special_handling' => package.respond_to?(:special_handling) ? package.special_handling : package.requires_special_handling?,
      'requires_payment_advance' => package.respond_to?(:requires_payment_advance) ? package.requires_payment_advance : false,
      'origin_agent' => serialize_agent(package.origin_agent),
      'destination_agent' => serialize_agent(package.destination_agent),
      'user' => serialize_user_basic(package.user),
      'tracking_url' => package.respond_to?(:tracking_url) ? package.tracking_url : nil,
      'route_description' => package.route_description,
      'display_identifier' => package.display_identifier,
      'updated_at' => package.updated_at
    }
    
    # Add collection-specific information if this is a collection package
    if package.collection?
      collection_data = {}
      
      [:shop_name, :shop_contact, :collection_address, :items_to_collect, 
       :item_value, :item_description, :collection_type].each do |attr|
        if package.respond_to?(attr)
          collection_data[attr.to_s] = package.send(attr)
        end
      end
      
      enhanced_data['collection_details'] = collection_data unless collection_data.empty?
    end
    
    # Add coordinate information if available
    if package.respond_to?(:pickup_latitude) && package.pickup_latitude
      enhanced_data['pickup_coordinates'] = {
        'latitude' => package.pickup_latitude,
        'longitude' => package.pickup_longitude
      }
    end
    
    if package.respond_to?(:delivery_latitude) && package.delivery_latitude
      enhanced_data['delivery_coordinates'] = {
        'latitude' => package.delivery_latitude,
        'longitude' => package.delivery_longitude
      }
    end
    
    base_data.merge(enhanced_data)
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

  # FIXED: Expanded strong parameters to accept all legitimate frontend fields including collection-specific ones
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
    
    permitted_params = params.require(:package).permit(*all_params)
    
    Rails.logger.info "📋 Permitted parameters: #{permitted_params.keys.join(', ')}"
    Rails.logger.info "📋 Delivery type: #{permitted_params[:delivery_type]}" if permitted_params[:delivery_type]
    
    permitted_params
  end

  def package_update_params
    base_params = [
      :sender_name, :sender_phone, :receiver_name, :receiver_phone, 
      :destination_area_id, :destination_agent_id, :delivery_type, :state,
      :origin_agent_id, :delivery_location
    ]
    
    # Add extended update parameters including collection-specific ones
    extended_params = [
      :sender_email, :receiver_email, :business_name, :special_instructions,
      :payment_method, :special_handling, :requires_payment_advance,
      :shop_name, :shop_contact, :collection_address, :items_to_collect,
      :item_value, :item_description, :collection_type
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
                           :sender_email, :receiver_email, :business_name, :special_instructions,
                           :shop_name, :shop_contact, :collection_address, :items_to_collect,
                           :item_value, :item_description].select do |field|
          all_params.include?(field)
        end
      end
    when 'admin'
      permitted_params = all_params
    when 'agent', 'rider', 'warehouse'
      permitted_params = [:state, :destination_area_id, :destination_agent_id, 
                         :delivery_location, :special_instructions,
                         :collection_address, :items_to_collect].select do |field|
        all_params.include?(field)
      end
    end
    
    params.require(:package).permit(*permitted_params)
  end
end