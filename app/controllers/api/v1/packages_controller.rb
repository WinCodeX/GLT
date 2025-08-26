# app/controllers/api/v1/packages_controller.rb - FIXED: Pricing integration, code generation, flexible phone validation
module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_package, only: [:show, :update, :destroy, :qr_code, :tracking_page, :pay, :submit]
      before_action :set_package_for_authenticated_user, only: [:pay, :submit, :update, :destroy, :qr_code]
      before_action :force_json_format

      def index
        begin
          packages = get_user_packages
          packages = apply_filters(packages)
          
          page = [params[:page]&.to_i || 1, 1].max
          per_page = [[params[:per_page]&.to_i || 20, 1].max, 100].min
          
          total_count = packages.count
          packages = packages.offset((page - 1) * per_page).limit(per_page)

          serialized_packages = packages.map do |package|
            serialize_package_with_complete_info(package)
          end

          render json: {
            success: true,
            data: serialized_packages,
            pagination: {
              current_page: page,
              per_page: per_page,
              total_count: total_count,
              total_pages: (total_count / per_page.to_f).ceil,
              has_next: page * per_page < total_count,
              has_prev: page > 1
            },
            user_context: {
              role: get_user_role,
              can_create_packages: can_create_packages?,
              user_id: current_user.id.to_s
            }
          }
        rescue => e
          Rails.logger.error "PackagesController#index error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { 
            success: false, 
            message: 'Failed to load packages',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def show
        begin
          unless can_access_package?(@package)
            return render json: {
              success: false,
              message: 'Access denied to this package'
            }, status: :forbidden
          end

          render json: {
            success: true,
            data: serialize_package_complete(@package),
            user_permissions: {
              can_edit: can_edit_package?(@package),
              can_delete: can_delete_package?(@package),
              available_scanning_actions: get_available_scanning_actions(@package)
            }
          }
        rescue => e
          Rails.logger.error "PackagesController#show error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load package details',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # FIXED: Integrated pricing system and removed phone validation restrictions
      def create
        unless can_create_packages?
          return render json: {
            success: false,
            message: 'Only customers can create packages'
          }, status: :forbidden
        end

        begin
          Rails.logger.info "📦 Starting package creation with raw params: #{params.inspect}"
          
          # Get creation parameters with maximum flexibility
          creation_params = extract_package_params
          Rails.logger.info "📦 Extracted params: #{creation_params.inspect}"
          
          # Validate only the absolute essentials (removed phone format validation)
          validation_errors = validate_essential_fields(creation_params)
          if validation_errors.any?
            Rails.logger.error "❌ Essential validation failed: #{validation_errors}"
            return render json: { 
              success: false,
              errors: validation_errors,
              message: validation_errors.join(', ')
            }, status: :unprocessable_entity
          end
          
          # Build package with validated parameters
          package = current_user.packages.build(creation_params)
          
          # Set area IDs from agents (if agents exist)
          set_area_ids_safely(package)
          
          # Set initial state
          package.state = 'pending_unpaid'
          
          # FIXED: Calculate cost using Price model/controller
          calculated_cost = calculate_package_price(package)
          if calculated_cost
            package.cost = calculated_cost
            Rails.logger.info "💰 Package cost calculated: KES #{calculated_cost}"
          else
            Rails.logger.warn "⚠️ Could not calculate cost, using default"
            package.cost = 200 # Set a default cost to prevent validation errors
          end
          
          # FIXED: Generate code and route_sequence using PackageCodeGenerator service
          if defined?(PackageCodeGenerator)
            begin
              code_generator = PackageCodeGenerator.new(package)
              generated_code = code_generator.generate
              package.code = generated_code
              Rails.logger.info "🔢 Package code generated: #{generated_code}"
              Rails.logger.info "📊 Route sequence set: #{package.route_sequence}"
            rescue => e
              Rails.logger.error "❌ PackageCodeGenerator failed: #{e.message}"
              Rails.logger.error e.backtrace.join("\n")
              # Set fallback values
              package.code = "PKG#{SecureRandom.hex(4).upcase}"
              package.route_sequence = 1
              Rails.logger.info "🔄 Using fallback code: #{package.code}"
            end
          else
            # Fallback if service not available
            package.code = "PKG#{SecureRandom.hex(4).upcase}"
            package.route_sequence = 1
            Rails.logger.info "⚠️ PackageCodeGenerator not available, using fallback: #{package.code}"
          end
          
          Rails.logger.info "🆕 Attempting to save package with: #{package.attributes.inspect}"

          if package.save
            Rails.logger.info "✅ Package created successfully with code: #{package.code || package.id}"
            
            render json: {
              success: true,
              data: serialize_package_complete(package),
              message: 'Package created successfully'
            }, status: :created
          else
            Rails.logger.error "❌ Package save failed: #{package.errors.full_messages.inspect}"
            render json: { 
              success: false,
              errors: package.errors.full_messages,
              message: "Save failed: #{package.errors.full_messages.join(', ')}"
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "PackagesController#create error: #{e.message}"
          Rails.logger.error "PackagesController#create backtrace: #{e.backtrace.join("\n")}"
          render json: { 
            success: false, 
            message: 'Package creation failed due to server error',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def update
        begin
          unless can_edit_package?(@package)
            return render json: {
              success: false,
              message: 'You cannot edit this package'
            }, status: :forbidden
          end

          filtered_params = package_update_params
          set_area_ids_safely(@package, filtered_params)

          # Recalculate cost if relevant fields changed
          if should_recalculate_cost?(filtered_params)
            # Create a temporary package with new values to calculate cost
            temp_package = @package.dup
            filtered_params.each { |key, value| temp_package.send("#{key}=", value) if temp_package.respond_to?("#{key}=") }
            
            new_cost = calculate_package_price(temp_package)
            if new_cost
              filtered_params[:cost] = new_cost
              Rails.logger.info "💰 Recalculated package cost: KES #{new_cost}"
            end
          end

          if filtered_params[:state] && filtered_params[:state] != @package.state
            unless valid_state_transition?(@package.state, filtered_params[:state])
              return render json: {
                success: false,
                message: "Invalid state transition from #{@package.state} to #{filtered_params[:state]}"
              }, status: :unprocessable_entity
            end
          end

          if @package.update(filtered_params)
            render json: {
              success: true,
              data: serialize_package_complete(@package.reload),
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
            message: 'An error occurred while updating the package',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def destroy
        begin
          unless can_delete_package?(@package)
            return render json: { 
              success: false, 
              message: 'You cannot delete this package' 
            }, status: :forbidden
          end

          unless can_be_deleted?(@package)
            return render json: { 
              success: false, 
              message: 'Package cannot be deleted in its current state' 
            }, status: :unprocessable_entity
          end

          if @package.destroy
            render json: { 
              success: true, 
              message: 'Package deleted successfully' 
            }
          else
            render json: { 
              success: false, 
              message: 'Failed to delete package',
              errors: @package.errors.full_messages 
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "PackagesController#destroy error: #{e.message}"
          render json: { 
            success: false, 
            message: 'An error occurred while deleting the package',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def search
        query = params[:query]&.strip
        
        if query.blank?
          return render json: { 
            success: false, 
            message: 'Search query is required' 
          }, status: :bad_request
        end

        begin
          packages = get_user_packages
                       .includes(:origin_area, :destination_area, :origin_agent, :destination_agent,
                                origin_area: :location, destination_area: :location)
                       .where("code ILIKE ?", "%#{query}%")
                       .limit(20)

          serialized_packages = packages.map do |package|
            serialize_package_with_complete_info(package)
          end

          render json: {
            success: true,
            data: serialized_packages,
            query: query,
            count: serialized_packages.length,
            user_role: get_user_role
          }
        rescue => e
          Rails.logger.error "PackagesController#search error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Search failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def qr_code
        begin
          Rails.logger.info "🔲 Generating QR code for package: #{@package.code}"
          
          if defined?(QrCodeGenerator)
            qr_generator = QrCodeGenerator.new(@package, qr_code_options)
            qr_base64 = qr_generator.generate_base64
            tracking_url = qr_generator.send(:generate_tracking_url_safely)
            
            render json: {
              success: true,
              data: {
                qr_code_base64: qr_base64,
                tracking_url: tracking_url,
                package_code: @package.code,
                package_state: @package.state,
                route_description: safe_route_description(@package)
              },
              message: 'QR code generated successfully'
            }
          else
            render json: {
              success: true,
              data: {
                qr_code_base64: nil,
                tracking_url: package_tracking_url(@package.code),
                package_code: @package.code,
                package_state: @package.state,
                route_description: safe_route_description(@package)
              },
              message: 'QR code service unavailable - tracking URL provided'
            }
          end
        rescue => e
          Rails.logger.error "PackagesController#qr_code error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to generate QR code',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def tracking_page
        begin
          render json: {
            success: true,
            data: serialize_package_complete(@package),
            timeline: package_timeline(@package),
            tracking_url: package_tracking_url(@package.code)
          }
        rescue => e
          Rails.logger.error "PackagesController#tracking_page error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load tracking information',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def pay
        begin
          if @package.state == 'pending_unpaid'
            @package.update!(state: 'pending')
            render json: { 
              success: true, 
              message: 'Payment processed successfully',
              data: serialize_package_basic(@package)
            }
          else
            render json: { 
              success: false, 
              message: 'Package is not pending payment' 
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "PackagesController#pay error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Payment processing failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def submit
        begin
          if @package.state == 'pending'
            @package.update!(state: 'submitted')
            render json: { 
              success: true, 
              message: 'Package submitted for delivery',
              data: serialize_package_basic(@package)
            }
          else
            render json: { 
              success: false, 
              message: 'Package must be pending to submit' 
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "PackagesController#submit error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Package submission failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      private

      # FIXED: Integrated pricing system using Price model
      def calculate_package_price(package)
        return nil unless package.origin_area && package.destination_area && package.delivery_type
        
        Rails.logger.info "💰 Calculating price for: origin=#{package.origin_area_id}, destination=#{package.destination_area_id}, delivery=#{package.delivery_type}"
        
        begin
          # Try to use the package's own pricing method first
          if package.respond_to?(:calculate_delivery_cost)
            cost = package.calculate_delivery_cost
            if cost && cost > 0
              Rails.logger.info "💰 Package model calculated cost: KES #{cost}"
              return cost
            end
          end
          
          # Use Price model to find exact pricing
          price_record = Price.find_by(
            origin_area_id: package.origin_area_id,
            destination_area_id: package.destination_area_id,
            delivery_type: package.delivery_type
          )
          
          if price_record
            Rails.logger.info "💰 Found price record: KES #{price_record.cost}"
            return price_record.cost
          end
          
          # Try with agent-specific pricing if available
          if package.origin_agent_id.present? || package.destination_agent_id.present?
            agent_price = Price.find_by(
              origin_area_id: package.origin_area_id,
              destination_area_id: package.destination_area_id,
              origin_agent_id: package.origin_agent_id,
              destination_agent_id: package.destination_agent_id,
              delivery_type: package.delivery_type
            )
            
            if agent_price
              Rails.logger.info "💰 Found agent-specific price: KES #{agent_price.cost}"
              return agent_price.cost
            end
          end
          
          # Fallback to calculated pricing based on location logic
          calculated_cost = calculate_fallback_pricing(package)
          Rails.logger.info "💰 Fallback pricing calculated: KES #{calculated_cost}"
          return calculated_cost
          
        rescue => e
          Rails.logger.error "💰 Pricing calculation error: #{e.message}"
          return calculate_fallback_pricing(package)
        end
      end

      # FIXED: Enhanced pricing with collection and fragile support
      def calculate_fallback_pricing(package)
        return 200 unless package.origin_area && package.destination_area
        
        # Check if same area
        is_intra_area = package.origin_area_id == package.destination_area_id
        
        # Check if same location
        origin_location_id = package.origin_area.location&.id
        destination_location_id = package.destination_area.location&.id
        is_intra_location = origin_location_id && destination_location_id && (origin_location_id == destination_location_id)
        
        base_cost = case package.delivery_type
        when 'agent'
          if is_intra_area
            120
          elsif is_intra_location
            150
          else
            180
          end
        when 'doorstep', 'mixed'
          if is_intra_area
            250
          elsif is_intra_location
            300
          else
            380
          end
        when 'fragile'
          # Fragile packages cost more due to special handling
          base = if is_intra_area
            350
          elsif is_intra_location
            420
          else
            580
          end
          base + 120 # Special handling surcharge
        when 'collection'
          # Collection service includes pickup + delivery + handling
          base = if is_intra_area
            400
          elsif is_intra_location
            500
          else
            650
          end
          
          # Add value-based fee for high-value items
          if package.respond_to?(:item_value) && package.item_value.to_f > 5000
            base + 100 # High-value item fee
          else
            base
          end
        else
          200
        end
        
        Rails.logger.info "💰 Fallback pricing: intra_area=#{is_intra_area}, intra_location=#{is_intra_location}, delivery=#{package.delivery_type}, cost=#{base_cost}"
        base_cost
      end

      def should_recalculate_cost?(params)
        cost_affecting_fields = [:origin_area_id, :destination_area_id, :delivery_type, :origin_agent_id, :destination_agent_id]
        cost_affecting_fields.any? { |field| params.key?(field) }
      end

      # FIXED: Safe user role detection
      def get_user_role
        return 'admin' if current_user.respond_to?(:admin?) && current_user.admin?
        return 'warehouse' if current_user.respond_to?(:warehouse?) && current_user.warehouse?
        return 'rider' if current_user.respond_to?(:rider?) && current_user.rider?
        return 'agent' if current_user.respond_to?(:agent?) && current_user.agent?
        return 'support' if current_user.respond_to?(:support_agent?) && current_user.support_agent?
        
        # Try primary_role method if available
        if current_user.respond_to?(:primary_role)
          return current_user.primary_role
        end
        
        # Try role checking via rolify
        if current_user.respond_to?(:has_role?)
          return 'admin' if current_user.has_role?(:admin)
          return 'warehouse' if current_user.has_role?(:warehouse)
          return 'rider' if current_user.has_role?(:rider)
          return 'agent' if current_user.has_role?(:agent)
          return 'support' if current_user.has_role?(:support)
        end
        
        # Default to client
        'client'
      end

      # FIXED: Safe package access method
      def get_user_packages
        packages = current_user.packages.includes(:origin_area, :destination_area, :origin_agent, :destination_agent,
                                                  origin_area: :location, destination_area: :location)
        
        # If user has accessible_packages method, use it
        if current_user.respond_to?(:accessible_packages)
          begin
            packages = current_user.accessible_packages
                                  .includes(:origin_area, :destination_area, :origin_agent, :destination_agent,
                                           origin_area: :location, destination_area: :location)
          rescue => e
            Rails.logger.warn "accessible_packages method failed, falling back to user.packages: #{e.message}"
          end
        end
        
        packages.order(created_at: :desc)
      end

      # FIXED: Robust parameter extraction
      def extract_package_params
        # Try different parameter structures the frontend might send
        package_data = params[:package] || params || {}
        
        base_params = {
          # Apply smart defaults like PackageHelper does
          sender_name: extract_with_default(package_data, :sender_name, get_default_sender_name),
          sender_phone: extract_with_default(package_data, :sender_phone, get_default_sender_phone),
          
          # Required fields - no defaults
          receiver_name: extract_value(package_data, :receiver_name),
          receiver_phone: extract_value(package_data, :receiver_phone),
          
          # Agent/area assignments
          origin_agent_id: extract_value(package_data, :origin_agent_id),
          destination_agent_id: extract_value(package_data, :destination_agent_id),
          origin_area_id: extract_value(package_data, :origin_area_id),
          destination_area_id: extract_value(package_data, :destination_area_id),
          
          # Delivery settings
          delivery_type: extract_with_default(package_data, :delivery_type, 'doorstep'),
          delivery_location: extract_value(package_data, :delivery_location),
          
          # Optional fields
          sender_email: extract_value(package_data, :sender_email),
          receiver_email: extract_value(package_data, :receiver_email),
          business_name: extract_value(package_data, :business_name)
        }
        
        # ADDED: Collection-specific fields
        if package_data[:delivery_type] == 'collection' || package_data['delivery_type'] == 'collection'
          collection_params = {
            shop_name: extract_value(package_data, :shop_name),
            shop_contact: extract_value(package_data, :shop_contact),
            collection_address: extract_value(package_data, :collection_address),
            items_to_collect: extract_value(package_data, :items_to_collect),
            item_value: extract_value(package_data, :item_value),
            item_description: extract_value(package_data, :item_description),
            special_instructions: extract_value(package_data, :special_instructions),
            payment_method: extract_with_default(package_data, :payment_method, 'mpesa'),
            pickup_latitude: extract_value(package_data, :pickup_latitude),
            pickup_longitude: extract_value(package_data, :pickup_longitude),
            delivery_latitude: extract_value(package_data, :delivery_latitude),
            delivery_longitude: extract_value(package_data, :delivery_longitude)
          }
          base_params.merge!(collection_params)
        end
        
        # ADDED: Fragile-specific fields
        if package_data[:delivery_type] == 'fragile' || package_data['delivery_type'] == 'fragile'
          fragile_params = {
            item_description: extract_value(package_data, :item_description),
            special_instructions: extract_value(package_data, :special_instructions),
            pickup_latitude: extract_value(package_data, :pickup_latitude),
            pickup_longitude: extract_value(package_data, :pickup_longitude),
            delivery_latitude: extract_value(package_data, :delivery_latitude),
            delivery_longitude: extract_value(package_data, :delivery_longitude)
          }
          base_params.merge!(fragile_params)
        end
        
        base_params.compact_blank
      end

      def extract_value(data, key)
        value = data[key] || data[key.to_s]
        value&.strip if value.respond_to?(:strip)
      end

      def extract_with_default(data, key, default)
        value = extract_value(data, key)
        value.present? ? value : default
      end

      def get_default_sender_name
        # Try various user name fields
        return current_user.name if current_user.respond_to?(:name) && current_user.name.present?
        return "#{current_user.first_name} #{current_user.last_name}".strip if current_user.respond_to?(:first_name) && current_user.respond_to?(:last_name) && (current_user.first_name.present? || current_user.last_name.present?)
        return current_user.first_name if current_user.respond_to?(:first_name) && current_user.first_name.present?
        return current_user.email.split('@').first.humanize if current_user.email.present?
        'Current User'
      end

      def get_default_sender_phone
        return current_user.phone if current_user.respond_to?(:phone) && current_user.phone.present?
        return current_user.phone_number if current_user.respond_to?(:phone_number) && current_user.phone_number.present?
        '+254700000000'
      end

      # FIXED: Enhanced validation for collection and fragile packages
      def validate_essential_fields(params)
        errors = []
        
        errors << 'Receiver name is required' if params[:receiver_name].blank?
        errors << 'Receiver phone is required' if params[:receiver_phone].blank?
        errors << 'Origin agent is required' if params[:origin_agent_id].blank?
        errors << 'Delivery type is required' if params[:delivery_type].blank?
        
        # Delivery-specific requirements
        case params[:delivery_type]
        when 'agent'
          errors << 'Destination agent is required for agent delivery' if params[:destination_agent_id].blank?
        when 'doorstep'
          errors << 'Delivery location is required for doorstep delivery' if params[:delivery_location].blank?
        when 'fragile'
          errors << 'Delivery location is required for fragile delivery' if params[:delivery_location].blank?
          errors << 'Item description is required for fragile items' if params[:item_description].blank?
        when 'collection'
          # Collection-specific validations
          errors << 'Shop name is required for collection service' if params[:shop_name].blank?
          errors << 'Shop contact is required for collection service' if params[:shop_contact].blank?
          errors << 'Collection address is required' if params[:collection_address].blank?
          errors << 'Items to collect description is required' if params[:items_to_collect].blank?
          errors << 'Item value is required for collection service' if params[:item_value].blank?
          
          # Validate item value is numeric and positive
          if params[:item_value].present?
            begin
              value = params[:item_value].to_f
              errors << 'Item value must be greater than 0' if value <= 0
            rescue
              errors << 'Item value must be a valid number'
            end
          end
        end
        
        errors
      end

      # FIXED: Safe area assignment
      def set_area_ids_safely(package, override_params = nil)
        params_to_use = override_params || package.attributes.symbolize_keys

        # Set origin area from origin agent
        if params_to_use[:origin_agent_id].present?
          begin
            agent = Agent.find(params_to_use[:origin_agent_id])
            if agent.respond_to?(:area_id) && agent.area_id.present?
              package.origin_area_id = agent.area_id
              Rails.logger.info "📍 Set origin_area_id=#{package.origin_area_id} from origin_agent"
            end
          rescue ActiveRecord::RecordNotFound => e
            Rails.logger.error "❌ Origin agent not found: #{params_to_use[:origin_agent_id]}"
          rescue => e
            Rails.logger.error "❌ Error setting origin area: #{e.message}"
          end
        end

        # Set destination area from destination agent
        if params_to_use[:destination_agent_id].present?
          begin
            agent = Agent.find(params_to_use[:destination_agent_id])
            if agent.respond_to?(:area_id) && agent.area_id.present?
              package.destination_area_id = agent.area_id
              Rails.logger.info "📍 Set destination_area_id=#{package.destination_area_id} from destination_agent"
            end
          rescue ActiveRecord::RecordNotFound => e
            Rails.logger.error "❌ Destination agent not found: #{params_to_use[:destination_agent_id]}"
          rescue => e
            Rails.logger.error "❌ Error setting destination area: #{e.message}"
          end
        end
        
        # Use explicit destination_area_id if provided
        if params_to_use[:destination_area_id].present?
          package.destination_area_id = params_to_use[:destination_area_id]
          Rails.logger.info "📍 Used explicit destination_area_id=#{package.destination_area_id}"
        end
      end

      # FIXED: Safe permission checks
      def can_create_packages?
        role = get_user_role
        ['client', 'customer'].include?(role) || role.nil? # Default to allowing creation
      end

      def can_access_package?(package)
        role = get_user_role
        
        case role
        when 'client', 'customer'
          package.user_id == current_user.id
        when 'agent', 'rider', 'warehouse', 'admin'
          true
        else
          package.user_id == current_user.id # Default to owner-only access
        end
      end

      def can_edit_package?(package)
        return false unless can_access_package?(package)
        
        role = get_user_role
        case role
        when 'client', 'customer'
          package.user_id == current_user.id && ['pending_unpaid', 'pending'].include?(package.state)
        when 'admin'
          true
        when 'agent', 'rider', 'warehouse'
          true
        else
          false
        end
      end

      def can_delete_package?(package)
        role = get_user_role
        case role
        when 'client', 'customer'
          package.user_id == current_user.id
        when 'admin'
          true
        else
          false
        end
      end

      def can_be_deleted?(package)
        ['pending_unpaid', 'pending'].include?(package.state)
      end

      def valid_state_transition?(from_state, to_state)
        valid_transitions = {
          'pending_unpaid' => ['pending', 'rejected'],
          'pending' => ['submitted', 'rejected'],
          'submitted' => ['in_transit', 'rejected'],
          'in_transit' => ['delivered', 'collected', 'returned'],
          'delivered' => ['collected'], # For collection packages
          'collected' => [], # Final state
          'returned' => [],
          'rejected' => []
        }
        
        valid_transitions[from_state]&.include?(to_state) || false
      end

      def get_available_scanning_actions(package)
        role = get_user_role
        return [] unless ['agent', 'rider', 'warehouse', 'admin'].include?(role)
        
        actions = []
        
        case role
        when 'agent'
          case package.state
          when 'submitted'
            actions << { action: 'collect', label: 'Collect Package', available: true }
          when 'in_transit'
            actions << { action: 'process', label: 'Process Package', available: true }
          end
        when 'rider'
          case package.state
          when 'submitted'
            actions << { action: 'collect', label: 'Collect for Delivery', available: true }
          when 'in_transit'
            actions << { action: 'deliver', label: 'Mark Delivered', available: true }
          end
        when 'warehouse'
          if ['submitted', 'in_transit'].include?(package.state)
            actions << { action: 'process', label: 'Process Package', available: true }
          end
        when 'admin'
          actions << { action: 'print', label: 'Print Label', available: true }
          actions << { action: 'collect', label: 'Collect Package', available: true }
          actions << { action: 'deliver', label: 'Mark Delivered', available: true }
          actions << { action: 'process', label: 'Process Package', available: true }
        end
        
        actions
      end

      def force_json_format
        request.format = :json
      end

      def set_package
        @package = Package.find_by!(code: params[:id])
        # Don't manually generate code - let Package model handle it via callbacks
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: 'Package not found' 
        }, status: :not_found
      end

      def set_package_for_authenticated_user
        @package = get_user_packages.find_by!(code: params[:id])
        # Don't manually generate code - let Package model handle it via callbacks
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: 'Package not found or access denied' 
        }, status: :not_found
      end

      # Serialization methods with safe field access
      def serialize_package_basic(package)
        {
          'id' => package.id.to_s,
          'code' => package.code || "PKG#{package.id}",
          'state' => package.state,
          'state_display' => package.state&.humanize,
          'sender_name' => package.sender_name,
          'receiver_name' => package.receiver_name,
          'receiver_phone' => package.receiver_phone,
          'cost' => package.cost,
          'delivery_type' => package.delivery_type,
          'route_description' => safe_route_description(package),
          'created_at' => package.created_at&.iso8601,
          'updated_at' => package.updated_at&.iso8601
        }
      end

      def serialize_package_with_complete_info(package)
        data = serialize_package_basic(package)
        
        data.merge!(
          'sender_phone' => get_sender_phone(package),
          'sender_email' => get_sender_email(package),
          'receiver_email' => get_receiver_email(package),
          'business_name' => get_business_name(package),
          'delivery_location' => safe_get(package, :delivery_location)
        )
        
        unless get_user_role == 'client'
          data.merge!(
            'access_reason' => get_access_reason(package),
            'user_can_scan' => ['agent', 'rider', 'warehouse', 'admin'].include?(get_user_role),
            'available_actions' => get_available_scanning_actions(package).map { |a| a[:action] }
          )
        end
        
        data
      end

      def serialize_package_complete(package)
        data = serialize_package_basic(package)
        
        additional_data = {
          'sender_phone' => get_sender_phone(package),
          'sender_email' => get_sender_email(package),
          'receiver_email' => get_receiver_email(package),
          'business_name' => get_business_name(package),
          'origin_area' => serialize_area(package.origin_area),
          'destination_area' => serialize_area(package.destination_area),
          'origin_agent' => serialize_agent(package.origin_agent),
          'destination_agent' => serialize_agent(package.destination_agent),
          'delivery_location' => safe_get(package, :delivery_location),
          'tracking_url' => package_tracking_url(package.code || "PKG#{package.id}"),
          'created_by' => serialize_user_basic(package.user),
          'is_editable' => can_edit_package?(package),
          'is_deletable' => can_delete_package?(package),
          'available_scanning_actions' => get_available_scanning_actions(package)
        }
        
        data.merge!(additional_data)
      end

      def get_access_reason(package)
        role = get_user_role
        case role
        when 'agent' then 'Agent access'
        when 'rider' then 'Delivery rider'
        when 'warehouse' then 'Warehouse staff'
        when 'admin' then 'Administrator'
        else 'User access'
        end
      end

      def serialize_area(area)
        return nil unless area
        {
          'id' => area.id.to_s,
          'name' => area.name,
          'location' => serialize_location(area.location)
        }
      end

      def serialize_location(location)
        return nil unless location
        {
          'id' => location.id.to_s,
          'name' => location.name,
          'state' => safe_get(location, :state),
          'country' => safe_get(location, :country)
        }
      end

      def serialize_agent(agent)
        return nil unless agent
        {
          'id' => agent.id.to_s,
          'name' => agent.name || 'Unknown Agent',
          'phone' => safe_get(agent, :phone),
          'area' => serialize_area(safe_get(agent, :area))
        }
      end

      def serialize_user_basic(user)
        return nil unless user
        
        name = get_default_sender_name
        
        {
          'id' => user.id.to_s,
          'name' => name,
          'email' => user.email,
          'role' => get_user_role
        }
      end

      # Safe field access helper
      def safe_get(object, field)
        return nil unless object
        object.respond_to?(field) ? object.send(field) : nil
      end

      def package_update_params
        permitted_fields = [
          :sender_name, :sender_phone, :receiver_name, :receiver_phone,
          :destination_area_id, :destination_agent_id, :delivery_type, :state,
          :origin_agent_id, :delivery_location, :cost
        ]
        
        # Add optional fields that exist in Package model
        optional_fields = [:sender_email, :receiver_email, :business_name]
        optional_fields.each do |field|
          permitted_fields << field if Package.column_names.include?(field.to_s)
        end
        
        params.fetch(:package, {}).permit(*permitted_fields)
      end

      def apply_filters(packages)
        packages = packages.where(state: params[:state]) if params[:state].present?
        packages = packages.where(delivery_type: params[:delivery_type]) if params[:delivery_type].present?
        packages
      end

      def qr_code_options
        {
          module_size: params[:module_size]&.to_i || 8,
          border_size: params[:border_size]&.to_i || 20,
          corner_radius: params[:corner_radius]&.to_i || 5,
          data_type: params[:data_type]&.to_sym || :url,
          center_logo: params[:center_logo] != 'false',
          gradient: params[:gradient] != 'false',
          logo_size: params[:logo_size]&.to_i || 30,
          qr_size: params[:qr_size]&.to_i || 6
        }
      end

      def safe_route_description(package)
        return "Unknown route" unless package.origin_area && package.destination_area
        
        if package.respond_to?(:route_description)
          package.route_description
        else
          origin_name = safe_get(package.origin_area, :name) || 'Unknown Origin'
          destination_name = safe_get(package.destination_area, :name) || 'Unknown Destination'
          "#{origin_name} → #{destination_name}"
        end
      end

      def package_timeline(package)
        return [] unless package.respond_to?(:tracking_events)
        
        package.tracking_events.order(:created_at).map do |event|
          {
            event_type: safe_get(event, :event_type),
            description: safe_get(event, :description),
            timestamp: event.created_at.iso8601,
            location: safe_get(event, :location),
            user: safe_get(event.user, :name) || 'System'
          }
        end
      rescue => e
        Rails.logger.error "Timeline generation failed: #{e.message}"
        []
      end

      def package_tracking_url(code)
        begin
          Rails.application.routes.url_helpers.package_tracking_url(code)
        rescue
          protocol = Rails.env.production? ? 'https' : 'http'
          host = 'localhost:3000'
          begin
            host = Rails.application.config.action_mailer.default_url_options[:host] if Rails.application.config.action_mailer.default_url_options.present?
          rescue
            # Use fallback host
          end
          "#{protocol}://#{host}/track/#{code}"
        end
      end

      def get_sender_phone(package)
        safe_get(package, :sender_phone)
      end

      def get_sender_email(package)
        safe_get(package, :sender_email) || safe_get(package.user, :email)
      end

      def get_receiver_email(package)
        safe_get(package, :receiver_email)
      end

      def get_business_name(package)
        safe_get(package, :business_name)
      end
    end
  end
end