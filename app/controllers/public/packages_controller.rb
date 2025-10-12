# app/controllers/public/packages_controller.rb
module Public
  class PackagesController < WebApplicationController
    # Allow public access - no authentication required for browsing
    skip_before_action :authenticate_user!, only: [:new, :create, :pricing]
    
    # Before actions
    before_action :set_form_data, only: [:new]
    before_action :validate_package_params, only: [:create]
    
    # GET /public/packages/new
    # Main package creation form - delivery_type parameter determines which form to show
    def new
      @delivery_type = params[:delivery_type] || 'home'
      @package = Package.new(delivery_type: @delivery_type)
      
      # Set default values based on delivery type
      case @delivery_type
      when 'fragile'
        @package.package_size = 'medium'
      when 'collection'
        @package.package_size = 'medium'
      when 'home', 'doorstep'
        @package.package_size = 'medium'
      when 'office', 'agent'
        @package.package_size = 'small'
      end
      
      respond_to do |format|
        format.html # renders new.html.erb
        format.json { render json: { form_data: @form_data } }
      end
    rescue => e
      Rails.logger.error "Error loading package creation form: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      redirect_to public_home_path, alert: 'Failed to load package creation form'
    end
    
    # POST /public/packages/create
    # Creates package after successful payment
    def create
      begin
        # Extract package data
        package_data = package_params
        
        # Calculate cost
        estimated_cost = calculate_package_cost(package_data)
        
        # Check if payment was successful
        unless payment_verified?(params[:mpesa_transaction_id])
          return render json: {
            success: false,
            message: 'Payment verification failed',
            error: 'payment_required'
          }, status: :payment_required
        end
        
        # Create the package
        package = Package.new(package_data)
        package.state = 'pending' # Already paid
        package.cost = estimated_cost
        package.code = generate_package_code(package)
        
        if package.save
          # Create tracking event
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
          
          # Send confirmation notification
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
    
    # POST /public/packages/calculate_pricing
    # Calculate pricing for package based on parameters
    def calculate_pricing
      begin
        package_data = pricing_params
        
        cost = calculate_package_cost(package_data)
        breakdown = calculate_cost_breakdown(package_data, cost)
        
        render json: {
          success: true,
          data: {
            total_cost: cost,
            breakdown: breakdown,
            delivery_type: package_data[:delivery_type],
            package_size: package_data[:package_size]
          }
        }
      rescue => e
        Rails.logger.error "Pricing calculation error: #{e.message}"
        
        render json: {
          success: false,
          message: 'Failed to calculate pricing',
          error: Rails.env.development? ? e.message : 'calculation_error'
        }, status: :unprocessable_entity
      end
    end
    
    # POST /public/packages/initiate_payment
    # Initiates M-Pesa STK push for package payment
    def initiate_payment
      begin
        phone_number = normalize_phone_number(params[:phone_number])
        amount = params[:amount].to_f
        package_reference = params[:package_reference] || "PKG-#{SecureRandom.hex(4).upcase}"
        
        # Validate parameters
        if phone_number.blank? || amount <= 0
          return render json: {
            success: false,
            message: 'Invalid payment parameters',
            error: 'validation_error'
          }, status: :bad_request
        end
        
        # Initiate M-Pesa STK push
        result = MpesaService.initiate_stk_push(
          phone_number: phone_number,
          amount: amount,
          account_reference: package_reference,
          transaction_desc: "Package payment - #{package_reference}"
        )
        
        if result[:success]
          # Store temporary transaction data in session
          session[:pending_package_payment] = {
            checkout_request_id: result[:data][:CheckoutRequestID],
            merchant_request_id: result[:data][:MerchantRequestID],
            phone_number: phone_number,
            amount: amount,
            package_reference: package_reference,
            initiated_at: Time.current
          }
          
          render json: {
            success: true,
            message: 'Payment initiated. Please check your phone.',
            checkout_request_id: result[:data][:CheckoutRequestID],
            merchant_request_id: result[:data][:MerchantRequestID]
          }
        else
          render json: {
            success: false,
            message: result[:message] || 'Failed to initiate payment',
            error: 'payment_initiation_failed'
          }, status: :unprocessable_entity
        end
        
      rescue => e
        Rails.logger.error "Payment initiation error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        
        render json: {
          success: false,
          message: 'Payment initiation failed',
          error: Rails.env.development? ? e.message : 'internal_error'
        }, status: :internal_server_error
      end
    end
    
    # GET /public/packages/check_payment_status
    # Check if payment has been completed
    def check_payment_status
      begin
        checkout_request_id = params[:checkout_request_id]
        
        unless checkout_request_id.present?
          return render json: {
            success: false,
            message: 'Checkout request ID required',
            error: 'validation_error'
          }, status: :bad_request
        end
        
        # Query payment status from M-Pesa
        result = MpesaService.query_stk_status(checkout_request_id)
        
        if result[:success]
          status = result[:data][:ResultCode] == '0' ? 'completed' : 'failed'
          
          render json: {
            success: true,
            payment_status: status,
            result_code: result[:data][:ResultCode],
            result_desc: result[:data][:ResultDesc],
            can_proceed: status == 'completed'
          }
        else
          render json: {
            success: false,
            message: 'Failed to check payment status',
            error: 'status_check_failed'
          }, status: :unprocessable_entity
        end
        
      rescue => e
        Rails.logger.error "Payment status check error: #{e.message}"
        
        render json: {
          success: false,
          message: 'Failed to check payment status',
          error: Rails.env.development? ? e.message : 'internal_error'
        }, status: :internal_server_error
      end
    end
    
    private
    
    def set_form_data
      @form_data = {
        areas: Area.includes(:location).order('locations.name, areas.name'),
        agents: Agent.includes(:area, :location).order(:name),
        locations: Location.order(:name),
        delivery_types: Package.delivery_types.keys,
        package_sizes: Package.package_sizes.keys
      }
    end
    
    def package_params
      params.require(:package).permit(
        :sender_name, :sender_phone, :sender_email,
        :receiver_name, :receiver_phone, :receiver_email,
        :delivery_type, :package_size,
        :origin_area_id, :destination_area_id,
        :origin_agent_id, :destination_agent_id,
        :pickup_location, :delivery_location,
        :package_description, :special_instructions,
        :shop_name, :shop_contact, :collection_address,
        :items_to_collect, :item_value, :item_description
      )
    end
    
    def pricing_params
      params.permit(
        :delivery_type, :package_size,
        :origin_area_id, :destination_area_id,
        :item_value
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
    
    def calculate_package_cost(package_data)
      base_cost = 150
      
      # Delivery type cost
      case package_data[:delivery_type]
      when 'doorstep', 'home'
        base_cost += 100
      when 'office'
        base_cost += 50
      when 'fragile'
        base_cost += 150
      when 'agent'
        base_cost += 0
      when 'collection'
        base_cost += 200
      end
      
      # Package size cost
      case package_data[:package_size]
      when 'small'
        base_cost *= 0.8
      when 'medium'
        base_cost *= 1.0
      when 'large'
        base_cost *= 1.4
      end
      
      # Area-based pricing
      if package_data[:origin_area_id] && package_data[:destination_area_id]
        origin_area = Area.find_by(id: package_data[:origin_area_id])
        dest_area = Area.find_by(id: package_data[:destination_area_id])
        
        if origin_area && dest_area
          if origin_area.location_id != dest_area.location_id
            base_cost += 200
          elsif origin_area.id != dest_area.id
            base_cost += 100
          else
            base_cost += 50
          end
        end
      end
      
      # Collection/fragile item value insurance
      if ['collection', 'fragile'].include?(package_data[:delivery_type]) && package_data[:item_value].present?
        item_value = package_data[:item_value].to_f
        insurance = [50, item_value * 0.02].max
        base_cost += insurance.round
      end
      
      base_cost.round
    end
    
    def calculate_cost_breakdown(package_data, total_cost)
      breakdown = {
        base_fee: 150,
        delivery_type_fee: 0,
        size_adjustment: 0,
        distance_fee: 0,
        insurance: 0
      }
      
      # Delivery type fee
      case package_data[:delivery_type]
      when 'doorstep', 'home'
        breakdown[:delivery_type_fee] = 100
      when 'office'
        breakdown[:delivery_type_fee] = 50
      when 'fragile'
        breakdown[:delivery_type_fee] = 150
      when 'collection'
        breakdown[:delivery_type_fee] = 200
      end
      
      # Insurance for collection/fragile
      if ['collection', 'fragile'].include?(package_data[:delivery_type]) && package_data[:item_value].present?
        item_value = package_data[:item_value].to_f
        breakdown[:insurance] = [50, item_value * 0.02].max.round
      end
      
      breakdown
    end
    
    def payment_verified?(transaction_id)
      return false if transaction_id.blank?
      
      # Check session for pending payment
      pending_payment = session[:pending_package_payment]
      return false unless pending_payment
      
      # Query M-Pesa to verify
      result = MpesaService.query_stk_status(pending_payment[:checkout_request_id])
      
      if result[:success] && result[:data][:ResultCode] == '0'
        # Clear session data
        session.delete(:pending_package_payment)
        return true
      end
      
      false
    rescue => e
      Rails.logger.error "Payment verification error: #{e.message}"
      false
    end
    
    def generate_package_code(package)
      prefix = case package.delivery_type
               when 'fragile' then 'FRG'
               when 'collection' then 'COL'
               when 'home', 'doorstep' then 'HOM'
               when 'office' then 'OFC'
               else 'PKG'
               end
      
      "#{prefix}-#{SecureRandom.hex(4).upcase}-#{Time.current.strftime('%Y%m%d')}"
    end
    
    def normalize_phone_number(phone)
      return nil if phone.blank?
      
      clean_phone = phone.gsub(/\D/, '')
      
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
    
    def send_creation_notification(package)
      # Send SMS/email notification logic here
      Rails.logger.info "Sending creation notification for package: #{package.code}"
    rescue => e
      Rails.logger.error "Failed to send creation notification: #{e.message}"
    end
  end
end