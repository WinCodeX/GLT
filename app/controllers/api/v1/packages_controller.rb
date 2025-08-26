# app/controllers/api/v1/packages_controller.rb - FIXED: Flexible package creation
module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_package, only: [:show, :update, :destroy, :qr_code, :tracking_page, :pay, :submit]
      before_action :set_package_for_authenticated_user, only: [:pay, :submit, :update, :destroy, :qr_code]
      before_action :force_json_format

      def index
        begin
          packages = current_user.accessible_packages
                                .includes(:origin_area, :destination_area, :origin_agent, :destination_agent, 
                                         origin_area: :location, destination_area: :location)
                                .order(created_at: :desc)
          
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
              role: current_user.primary_role,
              can_create_packages: current_user.client?,
              accessible_areas_count: current_user.accessible_areas.count,
              accessible_locations_count: current_user.accessible_locations.count
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
          unless current_user.can_access_package?(@package)
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

      # FIXED: Flexible package creation matching frontend expectations
      def create
        unless current_user.client?
          return render json: {
            success: false,
            message: 'Only customers can create packages'
          }, status: :forbidden
        end

        begin
          Rails.logger.info "📦 Starting flexible package creation with params: #{package_params}"
          
          # Get parameters with smart defaults (matching PackageHelper)
          creation_params = prepare_package_creation_params
          Rails.logger.info "📦 Prepared params with defaults: #{creation_params}"
          
          # Build package with prepared parameters
          package = current_user.packages.build(creation_params)
          
          # Smart area assignment from agents
          assign_areas_from_agents(package)
          
          # Only validate what's absolutely necessary
          validation_errors = validate_package_creation(package)
          if validation_errors.any?
            Rails.logger.error "❌ Package validation failed: #{validation_errors}"
            return render json: { 
              success: false,
              errors: validation_errors,
              message: 'Validation failed'
            }, status: :unprocessable_entity
          end
          
          # Set initial state - let model handle code generation
          package.state = 'pending_unpaid'
          
          Rails.logger.info "🆕 Creating package: origin_agent=#{package.origin_agent_id}, dest_agent=#{package.destination_agent_id}, delivery_type=#{package.delivery_type}"

          if package.save
            Rails.logger.info "✅ Package created successfully: #{package.code}"
            
            # Return exactly what PackageHelper expects
            render json: {
              success: true,
              data: serialize_package_complete(package),
              message: 'Package created successfully'
            }, status: :created
          else
            Rails.logger.error "❌ Package save failed: #{package.errors.full_messages}"
            render json: { 
              success: false,
              errors: package.errors.full_messages,
              message: 'Failed to create package'
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "PackagesController#create error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { 
            success: false, 
            message: 'An error occurred while creating the package',
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

          Rails.logger.info "🔄 Updating package #{@package.code}"

          filtered_params = package_update_params
          Rails.logger.info "🔄 Filtered update params: #{filtered_params}"

          # Set area IDs from agent IDs if agents are being updated
          if filtered_params[:origin_agent_id].present? || filtered_params[:destination_agent_id].present?
            assign_areas_from_agents(@package, filtered_params)
          end

          # Validate state transitions if state is being changed
          if filtered_params[:state] && filtered_params[:state] != @package.state
            unless valid_state_transition?(@package.state, filtered_params[:state])
              return render json: {
                success: false,
                message: "Invalid state transition from #{@package.state} to #{filtered_params[:state]}"
              }, status: :unprocessable_entity
            end
          end

          if @package.update(filtered_params)
            if should_recalculate_cost?(filtered_params)
              new_cost = calculate_package_cost(@package)
              @package.update_column(:cost, new_cost) if new_cost
            end

            Rails.logger.info "✅ Package #{@package.code} updated successfully"

            render json: {
              success: true,
              data: serialize_package_complete(@package.reload),
              message: 'Package updated successfully'
            }
          else
            Rails.logger.error "❌ Package update failed: #{@package.errors.full_messages}"
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
          packages = current_user.accessible_packages
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
            user_role: current_user.primary_role
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

      # FIXED: QR code generation using proper QrCodeGenerator service
      def qr_code
        begin
          Rails.logger.info "🔲 Generating QR code for package: #{@package.code}"
          
          # Use the QrCodeGenerator service from app/services
          if defined?(QrCodeGenerator)
            qr_generator = QrCodeGenerator.new(@package, qr_code_options)
            qr_base64 = qr_generator.generate_base64
            tracking_url = qr_generator.send(:generate_tracking_url_safely)
            
            Rails.logger.info "✅ QR code generated successfully using QrCodeGenerator service"
            
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
            # Fallback if service not available
            Rails.logger.warn "QrCodeGenerator service not available, using fallback"
            
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

      # FIXED: Smart parameter preparation with defaults (matching PackageHelper)
      def prepare_package_creation_params
        raw_params = package_params
        
        {
          # Smart defaults for sender info (matching PackageHelper logic)
          sender_name: raw_params[:sender_name].present? ? raw_params[:sender_name].strip : 'Current User',
          sender_phone: raw_params[:sender_phone].present? ? raw_params[:sender_phone].strip : '+254700000000',
          
          # Required fields (will be validated)
          receiver_name: raw_params[:receiver_name]&.strip || '',
          receiver_phone: raw_params[:receiver_phone]&.strip || '',
          
          # Agent and area assignments
          origin_agent_id: raw_params[:origin_agent_id],
          destination_agent_id: raw_params[:destination_agent_id],
          origin_area_id: raw_params[:origin_area_id], # Can be nil, will be set from agent
          destination_area_id: raw_params[:destination_area_id], # Can be nil, will be set from agent
          
          # Delivery settings with smart defaults
          delivery_type: raw_params[:delivery_type].present? ? raw_params[:delivery_type] : 'doorstep',
          delivery_location: raw_params[:delivery_location]&.strip,
          
          # Optional fields
          sender_email: raw_params[:sender_email]&.strip,
          receiver_email: raw_params[:receiver_email]&.strip,
          business_name: raw_params[:business_name]&.strip
        }.compact_blank # Remove empty string values
      end

      # FIXED: Flexible validation (only what's absolutely necessary)
      def validate_package_creation(package)
        errors = []
        
        # Only validate truly required fields
        if package.receiver_name.blank?
          errors << 'Receiver name is required'
        end
        
        if package.receiver_phone.blank?
          errors << 'Receiver phone is required'
        end
        
        if package.origin_agent_id.blank?
          errors << 'Origin agent is required'
        end
        
        if package.delivery_type.blank?
          errors << 'Delivery type is required'
        end
        
        # Validate phone format only if phone is present
        if package.sender_phone.present? && !package.sender_phone.match(/^\+254\d{9}$/)
          errors << 'Sender phone must be in format +254XXXXXXXXX'
        end
        
        if package.receiver_phone.present? && !package.receiver_phone.match(/^\+254\d{9}$/)
          errors << 'Receiver phone must be in format +254XXXXXXXXX'
        end
        
        # Delivery-specific validation (matching PackageHelper)
        if package.delivery_type == 'agent' && package.destination_agent_id.blank?
          errors << 'Destination agent is required for agent delivery'
        end
        
        if ['doorstep', 'fragile'].include?(package.delivery_type) && package.delivery_location.blank?
          errors << 'Delivery location is required for doorstep/fragile delivery'
        end
        
        # Validate origin agent exists (if provided)
        if package.origin_agent_id.present?
          begin
            origin_agent = Agent.find(package.origin_agent_id)
            unless current_user.can_access_agent?(origin_agent)
              errors << 'Access denied to selected origin agent'
            end
          rescue ActiveRecord::RecordNotFound
            errors << 'Selected origin agent not found'
          end
        end
        
        errors
      end

      # FIXED: Smart area assignment from agents
      def assign_areas_from_agents(package, params_override = nil)
        params_to_use = params_override || package.attributes.symbolize_keys

        # Set origin_area_id from origin_agent_id
        if params_to_use[:origin_agent_id].present?
          begin
            origin_agent = Agent.find(params_to_use[:origin_agent_id])
            if origin_agent.area_id.present?
              package.origin_area_id = origin_agent.area_id
              Rails.logger.info "📍 Set origin_area_id=#{package.origin_area_id} from origin_agent_id=#{params_to_use[:origin_agent_id]}"
            end
          rescue ActiveRecord::RecordNotFound
            Rails.logger.error "❌ Origin agent not found: #{params_to_use[:origin_agent_id]}"
          end
        end

        # Set destination_area_id from destination_agent_id (if provided)
        if params_to_use[:destination_agent_id].present?
          begin
            destination_agent = Agent.find(params_to_use[:destination_agent_id])
            if destination_agent.area_id.present?
              package.destination_area_id = destination_agent.area_id
              Rails.logger.info "📍 Set destination_area_id=#{package.destination_area_id} from destination_agent_id=#{params_to_use[:destination_agent_id]}"
            end
          rescue ActiveRecord::RecordNotFound
            Rails.logger.error "❌ Destination agent not found: #{params_to_use[:destination_agent_id]}"
          end
        end
        
        # Use explicit destination_area_id if provided (for non-agent delivery)
        if params_to_use[:destination_area_id].present? && package.destination_area_id != params_to_use[:destination_area_id]
          package.destination_area_id = params_to_use[:destination_area_id]
          Rails.logger.info "📍 Set destination_area_id=#{package.destination_area_id} from explicit parameter"
        end
      end

      def force_json_format
        request.format = :json
      end

      def set_package
        @package = Package.find_by!(code: params[:id])
        ensure_package_has_code(@package)
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
        ensure_package_has_code(@package)
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: 'Package not found or access denied' 
        }, status: :not_found
      end

      def ensure_package_has_code(package)
        return if package.code.present?
        
        if defined?(PackageCodeGenerator)
          package.update!(code: PackageCodeGenerator.new(package).generate)
        else
          package.update!(code: "PKG#{SecureRandom.hex(4).upcase}")
        end
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

      def can_be_deleted?(package)
        ['pending_unpaid', 'pending'].include?(package.state)
      end

      def valid_state_transition?(from_state, to_state)
        valid_transitions = {
          'pending_unpaid' => ['pending'],
          'pending' => ['submitted'],
          'submitted' => ['in_transit'],
          'in_transit' => ['delivered', 'returned'],
          'delivered' => [],
          'returned' => []
        }
        
        valid_transitions[from_state]&.include?(to_state) || false
      end

      def should_recalculate_cost?(params)
        params.key?(:destination_area_id) || params.key?(:destination_agent_id) || params.key?(:delivery_type)
      end

      def calculate_package_cost(package)
        return nil unless package.origin_area && package.destination_area
        
        if package.respond_to?(:calculate_delivery_cost)
          package.calculate_delivery_cost
        else
          base_cost = package.origin_area.id == package.destination_area.id ? 150 : 300
          case package.delivery_type
          when 'agent' then base_cost - 50
          when 'fragile' then base_cost + 100
          else base_cost
          end
        end
      end

      def get_available_scanning_actions(package)
        return [] unless current_user.respond_to?(:can_scan_packages?) && current_user.can_scan_packages?
        
        actions = []
        
        case current_user.primary_role
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

      def serialize_package_basic(package)
        {
          'id' => package.id.to_s,
          'code' => package.code,
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
          'delivery_location' => package.respond_to?(:delivery_location) ? package.delivery_location : nil
        )
        
        unless current_user.client?
          data.merge!(
            'access_reason' => get_access_reason(package),
            'user_can_scan' => current_user.respond_to?(:can_scan_packages?) ? current_user.can_scan_packages? : false,
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
          'delivery_location' => package.respond_to?(:delivery_location) ? package.delivery_location : nil,
          'tracking_url' => package_tracking_url(package.code),
          'created_by' => serialize_user_basic(package.user),
          'is_editable' => can_edit_package?(package),
          'is_deletable' => can_delete_package?(package),
          'available_scanning_actions' => get_available_scanning_actions(package)
        }
        
        data.merge!(additional_data)
      end

      def get_access_reason(package)
        case current_user.primary_role
        when 'agent'
          if current_user.respond_to?(:operates_in_area?) && current_user.operates_in_area?(package.origin_area_id)
            'Origin area agent'
          elsif current_user.respond_to?(:operates_in_area?) && current_user.operates_in_area?(package.destination_area_id)
            'Destination area agent'
          else
            'Agent access'
          end
        when 'rider'
          'Delivery rider'
        when 'warehouse'
          'Warehouse staff'
        when 'admin'
          'Administrator'
        else
          'Unknown'
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
          'state' => location.respond_to?(:state) ? location.state : nil,
          'country' => location.respond_to?(:country) ? location.country : nil
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

      # FIXED: Flexible parameter handling (don't force require anything)
      def package_params
        permitted_fields = [
          :sender_name, :sender_phone, :receiver_name, :receiver_phone,
          :origin_area_id, :destination_area_id, :origin_agent_id, :destination_agent_id,
          :delivery_type, :delivery_location
        ]
        
        # Add optional fields if they exist in the model
        optional_fields = [:sender_email, :receiver_email, :business_name]
        optional_fields.each do |field|
          permitted_fields << field if Package.column_names.include?(field.to_s)
        end
        
        # Use fetch with empty hash fallback to handle missing 'package' key gracefully
        params.fetch(:package, {}).permit(*permitted_fields)
      end

      def package_update_params
        base_params = [:sender_name, :sender_phone, :receiver_name, :receiver_phone, 
                      :destination_area_id, :destination_agent_id, :delivery_type, :state,
                      :origin_agent_id]
        
        optional_fields = [:delivery_location, :sender_email, :receiver_email, :business_name]
        optional_fields.each do |field|
          base_params << field if Package.column_names.include?(field.to_s)
        end
        
        permitted_params = []
        
        case current_user.primary_role
        when 'client'
          if ['pending_unpaid', 'pending'].include?(@package.state)
            permitted_params = [:sender_name, :sender_phone, :receiver_name, :receiver_phone, 
                               :destination_area_id, :destination_agent_id, :delivery_location,
                               :sender_email, :receiver_email, :business_name].select do |field|
              base_params.include?(field)
            end
          end
        when 'admin'
          permitted_params = base_params
        when 'agent', 'rider', 'warehouse'
          permitted_params = [:state, :destination_area_id, :destination_agent_id, :delivery_location].select do |field|
            base_params.include?(field)
          end
        end
        
        params.require(:package).permit(*permitted_params)
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
          origin_name = package.origin_area.location&.name || package.origin_area.name || 'Unknown Origin'
          destination_name = package.destination_area.location&.name || package.destination_area.name || 'Unknown Destination'
          
          if package.origin_area.location&.id == package.destination_area.location&.id
            "#{origin_name} (#{package.origin_area.name} → #{package.destination_area.name})"
          else
            "#{origin_name} → #{destination_name}"
          end
        end
      end

      def package_timeline(package)
        if package.respond_to?(:tracking_events)
          package.tracking_events.order(:created_at).map do |event|
            {
              event_type: event.event_type,
              description: event.description,
              timestamp: event.created_at.iso8601,
              location: event.location,
              user: event.user&.name || 'System'
            }
          end
        else
          []
        end
      end

      def package_tracking_url(code)
        begin
          Rails.application.routes.url_helpers.package_tracking_url(code)
        rescue
          protocol = Rails.env.production? ? 'https' : 'http'
          host = Rails.application.config.action_mailer.default_url_options[:host] || 'localhost:3000'
          "#{protocol}://#{host}/track/#{code}"
        end
      end

      def get_sender_phone(package)
        package.sender_phone
      end

      def get_sender_email(package)
        package.respond_to?(:sender_email) ? package.sender_email : nil
      end

      def get_receiver_email(package)
        package.respond_to?(:receiver_email) ? package.receiver_email : nil
      end

      def get_business_name(package)
        package.respond_to?(:business_name) ? package.business_name : nil
      end
    end
  end
end