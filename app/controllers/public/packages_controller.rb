# app/controllers/public/packages_controller.rb
module Public
  class PackagesController < WebApplicationController
    # Skip authentication for public package creation
    skip_before_action :authenticate_user!
    
    layout 'public_tracking'
    
    # GET /public/packages/new
    def new
      @delivery_type = params[:type] || 'home'
      @areas = Area.includes(:location).order('locations.name, areas.name')
      @agents = Agent.includes(area: :location).where(active: true).order('areas.name')
      
      # Initialize package with delivery type
      @package = Package.new(delivery_type: @delivery_type)
      
      render :new
    rescue => e
      Rails.logger.error "Error loading package form: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      redirect_to public_home_path, alert: 'Failed to load package creation form. Please try again.'
    end
    
    # POST /public/packages/calculate_cost
    def calculate_cost
      begin
        # Extract parameters
        origin_area_id = params[:origin_area_id]
        destination_area_id = params[:destination_area_id]
        delivery_type = params[:delivery_type]
        package_size = params[:package_size] || 'medium'
        
        # Validate required parameters
        if origin_area_id.blank? || destination_area_id.blank? || delivery_type.blank?
          return render json: {
            success: false,
            message: 'Missing required parameters'
          }, status: :bad_request
        end
        
        # Create temporary package for cost calculation
        temp_package = Package.new(
          origin_area_id: origin_area_id,
          destination_area_id: destination_area_id,
          delivery_type: delivery_type,
          package_size: package_size,
          state: 'pending_unpaid'
        )
        
        # Calculate cost
        cost = temp_package.calculate_delivery_cost || calculate_default_cost(temp_package)
        
        # Get route description
        origin_area = Area.find(origin_area_id)
        destination_area = Area.find(destination_area_id)
        
        route_description = if origin_area.location_id == destination_area.location_id
          "#{origin_area.location.name} (#{origin_area.name} → #{destination_area.name})"
        else
          "#{origin_area.location.name} → #{destination_area.location.name}"
        end
        
        render json: {
          success: true,
          cost: cost,
          route_description: route_description,
          breakdown: {
            base_cost: calculate_base_cost(delivery_type),
            size_adjustment: calculate_size_cost(package_size),
            route_cost: calculate_route_cost(origin_area, destination_area)
          }
        }
        
      rescue ActiveRecord::RecordNotFound => e
        render json: {
          success: false,
          message: 'Area or location not found'
        }, status: :not_found
      rescue => e
        Rails.logger.error "Cost calculation error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to calculate cost',
          error: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
      end
    end
    
    # POST /public/packages/initiate_payment
    def initiate_payment
      begin
        # Extract and validate parameters
        package_params = params.require(:package).permit(
          :sender_name, :sender_phone, :receiver_name, :receiver_phone,
          :origin_area_id, :destination_area_id, :origin_agent_id, :destination_agent_id,
          :delivery_type, :package_size, :delivery_location, :pickup_location,
          :package_description, :special_instructions
        )
        
        phone_number = package_params[:sender_phone]
        
        # Validate phone number
        unless valid_phone_number?(phone_number)
          return render json: {
            success: false,
            message: 'Invalid phone number format. Please use format: 254XXXXXXXXX or 07XXXXXXXX'
          }, status: :bad_request
        end
        
        # Create package in pending_unpaid state
        package = Package.new(package_params)
        package.state = 'pending_unpaid'
        package.user_id = nil # Public package - no user initially
        
        # Calculate cost
        package.cost = package.calculate_delivery_cost || calculate_default_cost(package)
        
        # Generate package code
        package.code = generate_package_code(package)
        
        # Save package
        unless package.save
          return render json: {
            success: false,
            message: 'Failed to create package',
            errors: package.errors.full_messages
          }, status: :unprocessable_entity
        end
        
        # Store package ID in session for payment verification
        session[:pending_package_id] = package.id
        
        # Normalize phone number for M-Pesa
        normalized_phone = normalize_phone_number(phone_number)
        
        # Initiate M-Pesa STK push
        result = MpesaService.initiate_stk_push(
          phone_number: normalized_phone,
          amount: package.cost,
          account_reference: package.code,
          transaction_desc: "Payment for package #{package.code}"
        )
        
        if result[:success]
          # Store transaction reference
          MpesaTransaction.create!(
            checkout_request_id: result[:data][:CheckoutRequestID],
            merchant_request_id: result[:data][:MerchantRequestID],
            package_id: package.id,
            user_id: nil,
            phone_number: normalized_phone,
            amount: package.cost,
            status: 'pending'
          )
          
          render json: {
            success: true,
            message: 'Payment initiated. Please check your phone for M-Pesa prompt.',
            package_code: package.code,
            checkout_request_id: result[:data][:CheckoutRequestID],
            amount: package.cost
          }
        else
          # Delete package if payment initiation failed
          package.destroy
          
          render json: {
            success: false,
            message: result[:message] || 'Failed to initiate payment',
            code: 'payment_failed'
          }, status: :unprocessable_entity
        end
        
      rescue ActiveRecord::RecordInvalid => e
        render json: {
          success: false,
          message: 'Invalid package data',
          errors: e.record.errors.full_messages
        }, status: :unprocessable_entity
      rescue => e
        Rails.logger.error "Payment initiation error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        
        render json: {
          success: false,
          message: 'Failed to initiate payment',
          error: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
      end
    end
    
    # GET /public/packages/:code/payment_status
    def payment_status
      begin
        package = Package.find_by!(code: params[:code])
        
        # Check if payment is completed
        if package.state == 'pending'
          render json: {
            success: true,
            status: 'completed',
            message: 'Payment successful',
            tracking_url: public_package_tracking_url(package.code)
          }
        elsif package.state == 'pending_unpaid'
          # Check M-Pesa transaction status
          transaction = package.mpesa_transactions.order(created_at: :desc).first
          
          if transaction
            render json: {
              success: true,
              status: transaction.status,
              message: case transaction.status
                when 'pending' then 'Waiting for payment confirmation'
                when 'failed' then 'Payment failed. Please try again.'
                when 'timeout' then 'Payment request timed out. Please try again.'
                else 'Processing payment'
              end
            }
          else
            render json: {
              success: false,
              status: 'no_transaction',
              message: 'No payment transaction found'
            }
          end
        else
          render json: {
            success: true,
            status: package.state,
            message: 'Package already processed'
          }
        end
        
      rescue ActiveRecord::RecordNotFound
        render json: {
          success: false,
          message: 'Package not found'
        }, status: :not_found
      rescue => e
        Rails.logger.error "Payment status check error: #{e.message}"
        render json: {
          success: false,
          message: 'Failed to check payment status',
          error: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
      end
    end
    
    private
    
    def valid_phone_number?(phone)
      return false if phone.blank?
      
      # Clean phone number
      clean = phone.gsub(/\D/, '')
      
      # Check if it's a valid Kenyan number
      clean.match?(/^(?:254|0)[17]\d{8}$/)
    end
    
    def normalize_phone_number(phone)
      return nil if phone.blank?
      
      # Remove any non-digit characters
      clean_phone = phone.gsub(/\D/, '')
      
      # Handle different formats
      if clean_phone.start_with?('254')
        clean_phone
      elsif clean_phone.start_with?('0')
        "254#{clean_phone[1..-1]}"
      elsif clean_phone.length == 9
        "254#{clean_phone}"
      else
        clean_phone
      end
    end
    
    def generate_package_code(package)
      date_prefix = Time.current.strftime('%Y%m%d')
      random_suffix = SecureRandom.hex(4).upcase
      
      type_prefix = case package.delivery_type
        when 'fragile' then 'FRG'
        when 'collection' then 'COL'
        when 'home', 'doorstep' then 'HOM'
        when 'office' then 'OFC'
        else 'PKG'
      end
      
      "#{type_prefix}-#{date_prefix}-#{random_suffix}"
    end
    
    def calculate_default_cost(package)
      base_cost = calculate_base_cost(package.delivery_type)
      size_cost = calculate_size_cost(package.package_size)
      
      # Add route cost if areas are present
      if package.origin_area && package.destination_area
        origin_location = package.origin_area.location
        destination_location = package.destination_area.location
        
        if origin_location && destination_location
          route_cost = calculate_route_cost(package.origin_area, package.destination_area)
          return base_cost + size_cost + route_cost
        end
      end
      
      base_cost + size_cost + 100 # Default route cost
    end
    
    def calculate_base_cost(delivery_type)
      case delivery_type
      when 'doorstep', 'home' then 200
      when 'office' then 150
      when 'agent' then 100
      when 'fragile' then 300
      when 'collection' then 250
      else 150
      end
    end
    
    def calculate_size_cost(package_size)
      case package_size
      when 'small' then 0
      when 'medium' then 50
      when 'large' then 120
      else 50
      end
    end
    
    def calculate_route_cost(origin_area, destination_area)
      if origin_area.location_id == destination_area.location_id
        if origin_area.id == destination_area.id
          50 # Same area
        else
          100 # Same location, different area
        end
      else
        200 # Different locations
      end
    end
  end
end