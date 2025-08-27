# app/controllers/api/v1/packages_controller.rb - Using QrCodeGenerator service with fixed serialization
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
                                         { origin_area: :location, destination_area: :location })
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
              accessible_areas_count: get_accessible_areas_count,
              accessible_locations_count: get_accessible_locations_count
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
          Rails.logger.error e.backtrace.join("\n")
          render json: { 
            success: false, 
            message: 'Failed to load package details',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def create
        unless current_user.client?
          return render json: {
            success: false,
            message: 'Only customers can create packages'
          }, status: :forbidden
        end

        begin
          package = current_user.packages.build(package_params)
          set_area_ids_from_agents(package)
          
          package.state = 'pending_unpaid'
          package.code = generate_package_code(package) if package.code.blank?
          package.cost = calculate_package_cost(package)

          if package.save
            Rails.logger.info "Package created successfully: #{package.code}"
            render json: {
              success: true,
              data: serialize_package_complete(package),
              message: 'Package created successfully'
            }, status: :created
          else
            render json: { 
              success: false,
              errors: package.errors.full_messages,
              message: 'Failed to create package'
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "PackagesController#create error: #{e.message}"
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

          filtered_params = package_update_params

          if filtered_params[:origin_agent_id].present? || filtered_params[:destination_agent_id].present?
            set_area_ids_from_agents(@package, filtered_params)
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
            if should_recalculate_cost?(filtered_params)
              new_cost = calculate_package_cost(@package)
              @package.update_column(:cost, new_cost) if new_cost
            end

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
          packages = current_user.accessible_packages
                                .includes(:origin_area, :destination_area, :origin_agent, :destination_agent,
                                         { origin_area: :location, destination_area: :location })
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

      def qr_code
        begin
          qr_data = generate_qr_code_data(@package)
          
          render json: {
            success: true,
            data: {
              qr_code_base64: qr_data[:base64],
              tracking_url: qr_data[:tracking_url],
              package_code: @package.code,
              package_state: @package.state,
              route_description: safe_route_description(@package)
            },
            message: 'QR code generated successfully'
          }
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

      def force_json_format
        request.format = :json
      end

      def set_package
        @package = Package.includes(:origin_area, :destination_area, :origin_agent, :destination_agent,
                                   { origin_area: :location, destination_area: :location }, :user)
                         .find_by!(code: params[:id])
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
                                        { origin_area: :location, destination_area: :location }, :user)
                               .find_by!(code: params[:id])
        ensure_package_has_code(@package)
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: 'Package not found or access denied' 
        }, status: :not_found
      end

      def apply_filters(packages)
        packages = packages.where(state: params[:state]) if params[:state].present?
        packages = packages.where("code ILIKE ?", "%#{params[:search]}%") if params[:search].present?
        
        case current_user.primary_role
        when 'agent'
          if params[:area_filter] == 'origin'
            packages = packages.where(origin_area_id: current_user.accessible_areas) if current_user.respond_to?(:accessible_areas)
          elsif params[:area_filter] == 'destination'
            packages = packages.where(destination_area_id: current_user.accessible_areas) if current_user.respond_to?(:accessible_areas)
          end
        when 'rider'
          if current_user.respond_to?(:accessible_areas) && current_user.accessible_areas.any?
            if params[:action_filter] == 'collection'
              packages = packages.where(origin_area_id: current_user.accessible_areas)
              packages = packages.where(state: 'submitted') if params[:state].blank?
            elsif params[:action_filter] == 'delivery'
              packages = packages.where(destination_area_id: current_user.accessible_areas)
              packages = packages.where(state: 'in_transit') if params[:state].blank?
            end
          end
        when 'warehouse'
          if current_user.respond_to?(:accessible_areas) && current_user.accessible_areas.any?
            packages = packages.where(
              "origin_area_id IN (?) OR destination_area_id IN (?)", 
              current_user.accessible_areas, current_user.accessible_areas
            )
          end
        end
        
        packages
      end

      def set_area_ids_from_agents(package, params_override = nil)
        params_to_use = params_override || package.attributes.symbolize_keys

        if params_to_use[:origin_agent_id].present?
          begin
            origin_agent = Agent.find(params_to_use[:origin_agent_id])
            package.origin_area_id = origin_agent.area_id
          rescue ActiveRecord::RecordNotFound
            Rails.logger.error "Origin agent not found: #{params_to_use[:origin_agent_id]}"
          end
        end

        if params_to_use[:destination_agent_id].present? && package.destination_area_id.blank?
          begin
            destination_agent = Agent.find(params_to_use[:destination_agent_id])
            package.destination_area_id = destination_agent.area_id
          rescue ActiveRecord::RecordNotFound
            Rails.logger.error "Destination agent not found: #{params_to_use[:destination_agent_id]}"
          end
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

      # FIXED: Safer serialization methods with proper nil checking
      def serialize_package_with_complete_info(package)
        data = serialize_package_basic(package)
        
        data.merge!(
          'sender_phone' => get_sender_phone(package),
          'sender_email' => get_sender_email(package),
          'receiver_email' => get_receiver_email(package),
          'business_name' => get_business_name(package),
          'delivery_location' => safe_get_delivery_location(package),
          'origin_area' => serialize_area(package.origin_area),
          'destination_area' => serialize_area(package.destination_area),
          'origin_agent' => serialize_agent(package.origin_agent),
          'destination_agent' => serialize_agent(package.destination_agent)
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
          'delivery_location' => safe_get_delivery_location(package),
          'tracking_url' => package_tracking_url(package.code),
          'created_by' => serialize_user_basic(package.user),
          'is_editable' => can_edit_package?(package),
          'is_deletable' => can_delete_package?(package),
          'available_scanning_actions' => get_available_scanning_actions(package)
        }
        
        data.merge!(additional_data)
      end

      def serialize_package_basic(package)
        {
          'id' => package.id.to_s,
          'code' => package.code || '',
          'state' => package.state || 'unknown',
          'state_display' => package.state&.humanize || 'Unknown',
          'sender_name' => package.sender_name || '',
          'receiver_name' => package.receiver_name || '',
          'receiver_phone' => package.receiver_phone || '',
          'cost' => package.cost || 0,
          'delivery_type' => package.delivery_type || 'agent',
          'route_description' => safe_route_description(package),
          'created_at' => package.created_at&.iso8601,
          'updated_at' => package.updated_at&.iso8601
        }
      end

      def serialize_area(area)
        return nil unless area
        
        {
          'id' => area.id.to_s,
          'name' => area.name || 'Unknown Area',
          'location' => serialize_location(area.location)
        }
      rescue => e
        Rails.logger.error "Error serializing area: #{e.message}"
        nil
      end

      def serialize_location(location)
        return nil unless location
        
        {
          'id' => location.id.to_s,
          'name' => location.name || 'Unknown Location'
        }
      rescue => e
        Rails.logger.error "Error serializing location: #{e.message}"
        nil
      end

      def serialize_agent(agent)
        return nil unless agent
        
        {
          'id' => agent.id.to_s,
          'name' => agent.name || 'Unknown Agent',
          'phone' => agent.phone || '',
          'area' => serialize_area(agent.area)
        }
      rescue => e
        Rails.logger.error "Error serializing agent: #{e.message}"
        nil
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
          'name' => name || 'Unknown User',
          'email' => user.email || '',
          'role' => user.respond_to?(:primary_role) ? user.primary_role : 'user'
        }
      rescue => e
        Rails.logger.error "Error serializing user: #{e.message}"
        {
          'id' => user&.id.to_s || '',
          'name' => 'Unknown User',
          'email' => '',
          'role' => 'user'
        }
      end

      def get_access_reason(package)
        case current_user.primary_role
        when 'agent'
          'Area agent access'
        when 'rider'
          'Delivery rider access'
        when 'warehouse'
          'Warehouse processing'
        when 'admin'
          'Administrator access'
        else
          'Package owner'
        end
      end

      # FIXED: Safer helper methods with nil checking
      def get_sender_phone(package)
        return nil unless package
        
        if package.respond_to?(:sender_phone) && package.sender_phone.present?
          package.sender_phone
        elsif package.user&.respond_to?(:phone) && package.user&.phone.present?
          package.user.phone
        else
          nil
        end
      rescue => e
        Rails.logger.error "Error getting sender phone: #{e.message}"
        nil
      end

      def get_sender_email(package)
        return nil unless package
        
        if package.respond_to?(:sender_email) && package.sender_email.present?
          package.sender_email
        elsif package.user&.respond_to?(:email) && package.user&.email.present?
          package.user.email
        else
          nil
        end
      rescue => e
        Rails.logger.error "Error getting sender email: #{e.message}"
        nil
      end

      def get_receiver_email(package)
        return nil unless package
        
        if package.respond_to?(:receiver_email) && package.receiver_email.present?
          package.receiver_email
        else
          nil
        end
      rescue => e
        Rails.logger.error "Error getting receiver email: #{e.message}"
        nil
      end

      def get_business_name(package)
        return nil unless package
        
        if package.respond_to?(:business_name) && package.business_name.present?
          package.business_name
        elsif package.user&.respond_to?(:business_name) && package.user&.business_name.present?
          package.user.business_name
        elsif package.user&.respond_to?(:company) && package.user&.company.present?
          package.user.company
        else
          nil
        end
      rescue => e
        Rails.logger.error "Error getting business name: #{e.message}"
        nil
      end

      def safe_get_delivery_location(package)
        return nil unless package
        
        if package.respond_to?(:delivery_location)
          package.delivery_location
        else
          nil
        end
      rescue => e
        Rails.logger.error "Error getting delivery location: #{e.message}"
        nil
      end

      # QR Code generation using the QrCodeGenerator service
      def generate_qr_code_data(package)
        tracking_url = package_tracking_url(package.code)
        
        if defined?(QrCodeGenerator)
          begin
            qr_generator = QrCodeGenerator.new(package, qr_code_options)
            png_data = qr_generator.generate
            return {
              base64: "data:image/png;base64,#{Base64.encode64(png_data)}",
              tracking_url: tracking_url
            }
          rescue => e
            Rails.logger.warn "QrCodeGenerator failed: #{e.message}"
          end
        end
        
        # Fallback if QrCodeGenerator is not available
        {
          base64: nil,
          tracking_url: tracking_url
        }
      end

      def qr_code_options
        {
          module_size: params[:module_size]&.to_i || 12,
          border_size: params[:border_size]&.to_i || 24,
          corner_radius: params[:corner_radius]&.to_i || 4,
          data_type: params[:data_type]&.to_sym || :url,
          center_logo: params[:center_logo] != 'false',
          gradient: params[:gradient] != 'false',
          logo_size: params[:logo_size]&.to_i || 40
        }
      end

      def valid_state_transition?(current_state, new_state)
        valid_transitions = {
          'pending_unpaid' => ['pending', 'rejected'],
          'pending' => ['submitted', 'rejected'],
          'submitted' => ['in_transit', 'rejected'],
          'in_transit' => ['delivered', 'rejected'],
          'delivered' => ['collected', 'rejected'],
          'collected' => [],
          'rejected' => ['pending']
        }

        return true if current_user.primary_role == 'admin'
        
        allowed_states = valid_transitions[current_state] || []
        allowed_states.include?(new_state)
      end

      def ensure_package_has_code(package)
        if package&.code.blank?
          package.update!(code: generate_package_code(package))
        end
      rescue => e
        Rails.logger.error "Failed to ensure package code: #{e.message}"
      end

      def generate_package_code(package)
        if defined?(PackageCodeGenerator)
          begin
            code_generator = PackageCodeGenerator.new(package)
            return code_generator.generate
          rescue => e
            Rails.logger.warn "PackageCodeGenerator failed: #{e.message}"
          end
        end
        
        "PKG-#{SecureRandom.hex(4).upcase}-#{Time.current.strftime('%Y%m%d')}"
      end

      def calculate_package_cost(package)
        if package.respond_to?(:calculate_delivery_cost)
          begin
            return package.calculate_delivery_cost
          rescue => e
            Rails.logger.warn "Package cost calculation method failed: #{e.message}"
          end
        end
        
        base_cost = 150
        
        case package.delivery_type
        when 'doorstep'
          base_cost += 100
        when 'fragile'
          base_cost += 150
        when 'agent'
          base_cost += 0
        when 'mixed'
          base_cost += 50
        end

        origin_location_id = package.origin_area&.location&.id
        destination_location_id = package.destination_area&.location&.id
        
        if origin_location_id && destination_location_id
          if origin_location_id != destination_location_id
            base_cost += 200
          else
            base_cost += 50
          end
        else
          if package.origin_area_id != package.destination_area_id
            base_cost += 100
          end
        end

        base_cost
      rescue => e
        Rails.logger.error "Cost calculation failed: #{e.message}"
        200
      end

      def should_recalculate_cost?(params)
        cost_affecting_fields = ['origin_area_id', 'destination_area_id', 'delivery_type']
        params.keys.any? { |key| cost_affecting_fields.include?(key) }
      end

      def package_params
        base_params = [
          :sender_name, :sender_phone, :receiver_name, :receiver_phone,
          :origin_area_id, :destination_area_id, :origin_agent_id, :destination_agent_id,
          :delivery_type
        ]
        
        optional_fields = [:delivery_location, :sender_email, :receiver_email, :business_name]
        optional_fields.each do |field|
          base_params << field if Package.column_names.include?(field.to_s)
        end
        
        params.require(:package).permit(*base_params)
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
        
        filtered_params = params.require(:package).permit(*permitted_params)
        
        if filtered_params[:state].present?
          valid_states = ['pending_unpaid', 'pending', 'submitted', 'in_transit', 'delivered', 'collected', 'rejected']
          unless valid_states.include?(filtered_params[:state])
            filtered_params.delete(:state)
          end
        end
        
        filtered_params
      end

      def can_be_deleted?(package)
        deletable_states = ['pending_unpaid', 'pending']
        deletable_states.include?(package.state)
      end

      def package_timeline(package)
        [
          {
            status: 'pending_unpaid',
            timestamp: package.created_at,
            description: 'Package created, awaiting payment',
            active: package.state == 'pending_unpaid'
          },
          {
            status: package.state,
            timestamp: package.updated_at,
            description: status_description(package.state),
            active: package.state != 'pending_unpaid'
          }
        ]
      rescue => e
        Rails.logger.error "Timeline generation failed: #{e.message}"
        [
          {
            status: package.state,
            timestamp: package.created_at,
            description: 'Package status available',
            active: true
          }
        ]
      end

      def package_tracking_url(code)
        "#{request.base_url}/track/#{code}"
      rescue => e
        Rails.logger.error "Tracking URL generation failed: #{e.message}"
        "/track/#{code}"
      end

      def safe_route_description(package)
        return 'Route information unavailable' unless package

        begin
          if package.respond_to?(:route_description) && package.route_description.present?
            package.route_description
          else
            origin_location = package.origin_area&.location&.name || 'Unknown Origin'
            destination_location = package.destination_area&.location&.name || 'Unknown Destination'
            
            if package.origin_area&.location&.id == package.destination_area&.location&.id
              origin_area = package.origin_area&.name || 'Unknown Area'
              destination_area = package.destination_area&.name || 'Unknown Area'
              "#{origin_location} (#{origin_area} → #{destination_area})"
            else
              "#{origin_location} → #{destination_location}"
            end
          end
        rescue => e
          Rails.logger.error "Route description generation failed: #{e.message}"
          origin = package.origin_area&.name || 'Unknown Origin'
          destination = package.destination_area&.name || 'Unknown Destination'
          "#{origin} → #{destination}"
        end
      end

      def status_description(state)
        case state
        when 'pending_unpaid'
          'Package created, awaiting payment'
        when 'pending'
          'Payment received, preparing for pickup'
        when 'submitted'
          'Package submitted for delivery'
        when 'in_transit'
          'Package is in transit'
        when 'delivered'
          'Package delivered successfully'
        when 'collected'
          'Package collected by receiver'
        when 'cancelled'
          'Package delivery cancelled'
        else
          state&.humanize || 'Unknown status'
        end
      end

      def get_accessible_areas_count
        return 0 unless current_user.respond_to?(:accessible_areas)
        current_user.accessible_areas.count
      rescue
        0
      end

      def get_accessible_locations_count
        return 0 unless current_user.respond_to?(:accessible_locations)
        current_user.accessible_locations.count
      rescue
        0
      end
    end
  end
end