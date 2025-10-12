# app/controllers/public/packages_controller.rb
module Public
  class PackagesController < WebApplicationController
    skip_before_action :authenticate_user!, only: [:new, :create, :calculate_pricing, :initiate_payment, :check_payment_status]
    
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
        
        # Fetch price from database
        price_record = Price.find_by(
          origin_area_id: origin_area_id,
          destination_area_id: destination_area_id,
          delivery_type: package_data[:delivery_type],
          package_size: package_data[:package_size]
        )
        
        unless price_record
          return render json: {
            success: false,
            message: 'Pricing not available for this route',
            error: 'price_not_found'
          }, status: :unprocessable_entity
        end
        
        estimated_cost = price_record.cost
        
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
        origin_area_id = params[:origin_area_id]
        destination_area_id = params[:destination_area_id]
        delivery_type = params[:delivery_type]
        package_size = params[:package_size]
        
        unless origin_area_id && destination_area_id && delivery_type && package_size
          return render json: {
            success: false,
            message: 'Missing required parameters',
            error: 'validation_error'
          }, status: :bad_request
        end
        
        # Fetch price from database
        price_record = Price.find_by(
          origin_area_id: origin_area_id,
          destination_area_id: destination_area_id,
          delivery_type: delivery_type,
          package_size: package_size
        )
        
        if price_record
          render json: {
            success: true,
            data: {
              total_cost: price_record.cost,
              delivery_type: delivery_type,
              package_size: package_size,
              origin_area: price_record.origin_area.name,
              destination_area: price_record.destination_area.name
            }
          }
        else
          render json: {
            success: false,
            message: 'Pricing not available for this route and delivery type',
            error: 'price_not_found'
          }, status: :not_found
        end
      rescue => e
        Rails.logger.error "Pricing calculation error: #{e.message}"
        
        render json: {
          success: false,
          message: 'Failed to calculate pricing',
          error: Rails.env.development? ? e.message : 'calculation_error'
        }, status: :unprocessable_entity
      end
    end
    
    def initiate_payment
      begin
        phone_number = normalize_phone_number(params[:phone_number])
        amount = params[:amount].to_f
        package_reference = params[:package_reference] || "PKG-#{SecureRandom.hex(4).upcase}"
        
        if phone_number.blank? || amount <= 0
          return render json: {
            success: false,
            message: 'Invalid payment parameters',
            error: 'validation_error'
          }, status: :bad_request
        end
        
        result = MpesaService.initiate_stk_push(
          phone_number: phone_number,
          amount: amount,
          account_reference: package_reference,
          transaction_desc: "Package payment - #{package_reference}"
        )
        
        if result[:success]
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
        agents: Agent.includes(:area, :location).where(active: true).order(:name),
        locations: Location.order(:name),
        delivery_types: Package.delivery_types.keys,
        package_sizes: Package.package_sizes.keys
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
    
    def payment_verified?(transaction_id)
      return false if transaction_id.blank?
      
      pending_payment = session[:pending_package_payment]
      return false unless pending_payment
      
      result = MpesaService.query_stk_status(pending_payment[:checkout_request_id])
      
      if result[:success] && result[:data][:ResultCode] == '0'
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
               when 'home' then 'HOM'
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
      Rails.logger.info "Sending creation notification for package: #{package.code}"
    rescue => e
      Rails.logger.error "Failed to send creation notification: #{e.message}"
    end
  end
end