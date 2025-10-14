# app/controllers/public/packages_controller.rb
module Public
  class PackagesController < WebApplicationController
    skip_before_action :authenticate_user!, only: [:new, :create, :calculate_pricing]
    skip_before_action :verify_authenticity_token, only: [:calculate_pricing]
    
    before_action :set_form_data, only: [:new]
    before_action :validate_package_params, only: [:create]
    
    def new
      @delivery_type = params[:delivery_type] || 'home'
      @package = Package.new(delivery_type: @delivery_type)
      
      # Set default values based on delivery type
      case @delivery_type
      when 'fragile', 'collection'
        @package.package_size = 'medium'
      when 'home'
        @package.package_size = 'medium'
      when 'office'
        @package.package_size = 'small'
      end
      
      respond_to do |format|
        format.html
        format.json { render json: { form_data: @form_data } }
      end
    rescue => e
      Rails.logger.error "Error loading package creation form: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      redirect_to public_home_path, alert: 'Failed to load package creation form'
    end
    
    def create
      begin
        package_data = package_params
        
        # Get origin and destination areas based on delivery type
        origin_area_id, destination_area_id = get_route_areas(package_data)
        
        unless origin_area_id && destination_area_id
          return render json: {
            success: false,
            message: 'Invalid route configuration',
            error: 'invalid_route'
          }, status: :bad_request
        end
        
        # Calculate price using the same logic as prices_controller
        estimated_cost = calculate_delivery_cost(
          origin_area_id, 
          destination_area_id, 
          package_data[:delivery_type], 
          package_data[:package_size]
        )
        
        unless estimated_cost
          return render json: {
            success: false,
            message: 'Unable to calculate pricing for this route',
            error: 'price_calculation_failed'
          }, status: :unprocessable_entity
        end
        
        # Verify payment
        unless payment_verified?(params[:mpesa_transaction_id])
          return render json: {
            success: false,
            message: 'Payment verification failed',
            error: 'payment_required'
          }, status: :payment_required
        end
        
        # Create package
        package = Package.new(package_data)
        package.origin_area_id = origin_area_id
        package.destination_area_id = destination_area_id
        package.state = 'pending'
        package.cost = estimated_cost
        package.code = generate_package_code(package)
        
        if package.save
          package.tracking_events.create!(
            event_type: 'created',
            description: 'Package created via web',
            user_id: package.user_id,
            metadata: {
              payment_method: 'mpesa',
              transaction_id: params[:mpesa_transaction_id],
              created_via: 'web'
            }
          )
          
          # Clear payment session
          session.delete(:pending_package_payment)
          
          send_creation_notification(package)
          
          respond_to do |format|
            format.html { redirect_to public_package_tracking_path(package.code), notice: 'Package created successfully!' }
            format.json {
              render json: {
                success: true,
                message: 'Package created successfully',
                data: {
                  package_code: package.code,
                  tracking_url: public_package_tracking_url(package.code),
                  cost: package.cost,
                  state: package.state
                }
              }, status: :created
            }
          end
        else
          render json: {
            success: false,
            message: 'Failed to create package',
            errors: package.errors.full_messages
          }, status: :unprocessable_entity
        end
        
      rescue => e
        Rails.logger.error "Package creation error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        
        render json: {
          success: false,
          message: 'An error occurred while creating the package',
          error: Rails.env.development? ? e.message : 'internal_error'
        }, status: :internal_server_error
      end
    end
    
    def calculate_pricing
      begin
        # Parse JSON body if present, otherwise use params
        request_data = if request.content_type&.include?('application/json') && request.body.read.present?
          request.body.rewind
          JSON.parse(request.body.read).with_indifferent_access
        else
          params
        end
        
        origin_area_id = request_data[:origin_area_id]
        destination_area_id = request_data[:destination_area_id]
        delivery_type = request_data[:delivery_type]
        package_size = request_data[:package_size]
        
        # Enhanced logging for debugging
        Rails.logger.info "===== CALCULATE PRICING REQUEST ====="
        Rails.logger.info "Origin Area ID: #{origin_area_id}"
        Rails.logger.info "Destination Area ID: #{destination_area_id}"
        Rails.logger.info "Delivery Type: #{delivery_type}"
        Rails.logger.info "Package Size: #{package_size}"
        Rails.logger.info "Request Content-Type: #{request.content_type}"
        Rails.logger.info "======================================"
        
        unless origin_area_id && destination_area_id && delivery_type && package_size
          return render json: {
            success: false,
            message: 'Missing required parameters',
            error: 'validation_error',
            received_params: {
              origin_area_id: origin_area_id,
              destination_area_id: destination_area_id,
              delivery_type: delivery_type,
              package_size: package_size
            }
          }, status: :bad_request
        end
        
        # Find areas
        origin_area = Area.find_by(id: origin_area_id)
        destination_area = Area.find_by(id: destination_area_id)
        
        unless origin_area && destination_area
          return render json: {
            success: false,
            message: 'Invalid area IDs',
            error: 'area_not_found'
          }, status: :not_found
        end
        
        # Calculate cost using the same logic as prices_controller
        total_cost = calculate_delivery_cost(origin_area_id, destination_area_id, delivery_type, package_size)
        
        if total_cost
          Rails.logger.info "✓ Price calculated successfully: KES #{total_cost}"
          Rails.logger.info "  Route: #{origin_area.name} (#{origin_area.location.name}) → #{destination_area.name} (#{destination_area.location.name})"
          Rails.logger.info "  Type: #{delivery_type}, Size: #{package_size}"
          
          render json: {
            success: true,
            data: {
              total_cost: total_cost,
              delivery_type: delivery_type,
              package_size: package_size,
              origin_area: origin_area.name,
              destination_area: destination_area.name
            }
          }
        else
          Rails.logger.error "✗ Failed to calculate price"
          Rails.logger.error "  Origin: #{origin_area&.name}, Destination: #{destination_area&.name}"
          
          render json: {
            success: false,
            message: 'Unable to calculate pricing',
            error: 'calculation_failed'
          }, status: :unprocessable_entity
        end
        
      rescue JSON::ParserError => e
        Rails.logger.error "JSON Parse Error: #{e.message}"
        render json: {
          success: false,
          message: 'Invalid JSON format',
          error: 'parse_error'
        }, status: :bad_request
      rescue => e
        Rails.logger.error "Pricing calculation error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        
        render json: {
          success: false,
          message: 'Failed to calculate pricing',
          error: Rails.env.development? ? e.message : 'calculation_error'
        }, status: :unprocessable_entity
      end
    end
    
    private
    
    def set_form_data
      # Check if Agent model has active column
      has_active = Agent.column_names.include?('active')
      
      @form_data = {
        areas: Area.includes(:location).order('locations.name, areas.name'),
        agents: has_active ? Agent.includes(:area, :location).where(active: true).order(:name) : Agent.includes(:area, :location).order(:name),
        locations: Location.order(:name),
        delivery_types: ['home', 'office', 'fragile', 'collection'],
        package_sizes: ['small', 'medium', 'large']
      }
    rescue => e
      Rails.logger.error "Error in set_form_data: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      # Provide minimal fallback data
      @form_data = {
        areas: Area.all,
        agents: Agent.all,
        locations: Location.all,
        delivery_types: ['home', 'office', 'fragile', 'collection'],
        package_sizes: ['small', 'medium', 'large']
      }
    end
    
    def package_params
      params.require(:package).permit(
        :sender_name, :sender_phone,
        :receiver_name, :receiver_phone,
        :delivery_type, :package_size,
        :origin_area_id, :destination_area_id,
        :origin_agent_id, :destination_agent_id,
        :pickup_location, :delivery_location,
        :package_description, :special_instructions,
        :shop_name, :shop_contact, :collection_address,
        :items_to_collect, :item_value, :item_description
      )
    end
    
    def validate_package_params
      required_fields = [:sender_name, :sender_phone, :receiver_name, :receiver_phone, :delivery_type]
      
      missing_fields = required_fields.select { |field| params.dig(:package, field).blank? }
      
      if missing_fields.any?
        render json: {
          success: false,
          message: 'Missing required fields',
          missing_fields: missing_fields,
          error: 'validation_error'
        }, status: :bad_request
      end
    end
    
    def get_route_areas(package_data)
      case package_data[:delivery_type]
      when 'home'
        # Home: Agent to Area
        origin_agent = Agent.find_by(id: package_data[:origin_agent_id])
        destination_area_id = package_data[:destination_area_id]
        
        return nil, nil unless origin_agent && destination_area_id
        
        [origin_agent.area_id, destination_area_id]
        
      when 'office'
        # Office: Agent to Agent
        origin_agent = Agent.find_by(id: package_data[:origin_agent_id])
        destination_agent = Agent.find_by(id: package_data[:destination_agent_id])
        
        return nil, nil unless origin_agent && destination_agent
        
        [origin_agent.area_id, destination_agent.area_id]
        
      when 'fragile', 'collection'
        # Fragile/Collection: Area to Area
        origin_area_id = package_data[:origin_area_id]
        destination_area_id = package_data[:destination_area_id]
        
        return nil, nil unless origin_area_id && destination_area_id
        
        [origin_area_id, destination_area_id]
        
      else
        [nil, nil]
      end
    end
    
    # Calculate delivery cost using the same logic as Api::V1::PricesController
    def calculate_delivery_cost(origin_area_id, destination_area_id, delivery_type, package_size)
      origin_area = Area.includes(:location).find_by(id: origin_area_id)
      destination_area = Area.includes(:location).find_by(id: destination_area_id)
      
      return nil unless origin_area && destination_area
      
      is_intra_area = origin_area.id == destination_area.id
      is_intra_location = origin_area.location_id == destination_area.location_id
      
      base_cost = calculate_base_cost(origin_area, destination_area, is_intra_area, is_intra_location)
      size_multiplier = get_package_size_multiplier(package_size)
      
      case delivery_type.to_s.downcase
      when 'fragile'
        calculate_fragile_price(base_cost, size_multiplier)
      when 'home', 'doorstep'
        calculate_home_price(base_cost, size_multiplier, is_intra_area, is_intra_location)
      when 'office', 'agent'
        calculate_office_price(base_cost, size_multiplier, is_intra_area, is_intra_location)
      when 'collection'
        calculate_collection_price(base_cost, size_multiplier)
      else
        calculate_home_price(base_cost, size_multiplier, is_intra_area, is_intra_location)
      end
    rescue => e
      Rails.logger.error "Cost calculation error: #{e.message}"
      nil
    end
    
    def calculate_base_cost(origin_area, destination_area, is_intra_area, is_intra_location)
      if is_intra_area
        200 # Same area base cost
      elsif is_intra_location
        280 # Same location, different areas
      else
        # Inter-location pricing
        calculate_inter_location_cost(origin_area.location, destination_area.location)
      end
    end
    
    def calculate_inter_location_cost(origin_location, destination_location)
      return 350 unless origin_location && destination_location
      
      # Major route pricing
      major_routes = {
        ['Nairobi', 'Mombasa'] => 420,
        ['Nairobi', 'Kisumu'] => 400,
        ['Mombasa', 'Kisumu'] => 390
      }
      
      route_key = [origin_location.name, destination_location.name].sort
      major_routes[route_key] || (
        # Default inter-location pricing
        if origin_location.name == 'Nairobi' || destination_location.name == 'Nairobi'
          380
        else
          370
        end
      )
    end
    
    def get_package_size_multiplier(package_size)
      case package_size.to_s.downcase
      when 'small'
        0.8
      when 'medium'
        1.0
      when 'large'
        1.4
      else
        1.0
      end
    end
    
    def calculate_fragile_price(base_cost, size_multiplier)
      fragile_base = base_cost * 1.5 # 50% premium for fragile handling
      fragile_surcharge = 100 # Fixed surcharge for special handling
      
      ((fragile_base + fragile_surcharge) * size_multiplier).round
    end
    
    def calculate_home_price(base_cost, size_multiplier, is_intra_area, is_intra_location)
      home_base = if is_intra_area
        base_cost * 1.2 # 20% premium for doorstep delivery within area
      elsif is_intra_location
        base_cost * 1.1 # 10% premium for doorstep delivery within location
      else
        base_cost # Standard inter-location pricing
      end
      
      (home_base * size_multiplier).round
    end
    
    def calculate_office_price(base_cost, size_multiplier, is_intra_area, is_intra_location)
      office_discount = 0.75 # 25% discount for office collection
      office_base = base_cost * office_discount
      
      (office_base * size_multiplier).round
    end
    
    def calculate_collection_price(base_cost, size_multiplier)
      collection_base = base_cost * 1.3 # 30% premium for collection service
      collection_surcharge = 50 # Fixed surcharge for collection logistics
      
      ((collection_base + collection_surcharge) * size_multiplier).round
    end
    
    def payment_verified?(transaction_id)
      return false if transaction_id.blank?
      
      pending_payment = session[:pending_package_payment]
      return false unless pending_payment
      
      # Check if this is the correct checkout request
      return false unless pending_payment[:checkout_request_id] == transaction_id
      
      # Query M-Pesa to verify payment
      result = MpesaService.query_stk_status(transaction_id)
      
      if result[:success] && result[:data]['ResultCode'].to_i == 0
        Rails.logger.info "✅ Payment verified for checkout_request_id: #{transaction_id}"
        return true
      end
      
      Rails.logger.warn "❌ Payment verification failed for checkout_request_id: #{transaction_id}"
      false
    rescue => e
      Rails.logger.error "Payment verification error: #{e.message}"
      false
    end
    
    def generate_package_code(package)
      # Use PackageCodeGenerator if available (same as API controller)
      if defined?(PackageCodeGenerator)
        begin
          code_generator = PackageCodeGenerator.new(package)
          return code_generator.generate
        rescue => e
          Rails.logger.warn "PackageCodeGenerator failed: #{e.message}"
        end
      end
      
      # Fallback to simple format (consistent with API controller)
      "PKG-#{SecureRandom.hex(4).upcase}-#{Time.current.strftime('%Y%m%d')}"
    end
    
    def send_creation_notification(package)
      Rails.logger.info "Sending creation notification for package: #{package.code}"
    rescue => e
      Rails.logger.error "Failed to send creation notification: #{e.message}"
    end
  end
end