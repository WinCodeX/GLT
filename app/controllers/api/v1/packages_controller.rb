# app/controllers/api/v1/packages_controller.rb - FIXED: User serialization and state transitions
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

      def create
        unless current_user.client?
          return render json: {
            success: false,
            message: 'Only customers can create packages'
          }, status: :forbidden
        end

        begin
          package = current_user.packages.build(package_params)
          package.state = 'pending_unpaid'
          package.code = generate_package_code(package)
          package.cost = calculate_package_cost(package)

          if package.save
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
          Rails.logger.info "🔄 Current user role: #{current_user.primary_role}"
          Rails.logger.info "🔄 Current package state: #{@package.state}"

          filtered_params = package_update_params
          Rails.logger.info "🔄 Filtered update params: #{filtered_params}"

          # FIXED: Validate state transitions if state is being changed
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
          Rails.logger.error e.backtrace.join("\n")
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
        return [] unless current_user.can_scan_packages?
        
        actions = []
        
        if current_user.can_perform_action?('print', package)
          actions << { action: 'print', label: 'Print Label', available: true }
        end
        
        if current_user.can_perform_action?('collect', package)
          actions << { action: 'collect', label: 'Collect Package', available: true }
        end
        
        if current_user.can_perform_action?('deliver', package)
          actions << { action: 'deliver', label: 'Mark Delivered', available: true }
        end
        
        if current_user.can_perform_action?('process', package)
          actions << { action: 'process', label: 'Process Package', available: true }
        end
        
        actions
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
            'user_can_scan' => current_user.can_scan_packages?,
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
        data
      end

      def get_access_reason(package)
        case current_user.primary_role
        when 'agent'
          if current_user.operates_in_area?(package.origin_area_id)
            'Origin area agent'
          elsif current_user.operates_in_area?(package.destination_area_id)
            'Destination area agent'
          else
            'Area access'
          end
        when 'rider'
          if current_user.operates_in_area?(package.origin_area_id)
            'Collection area rider'
          elsif current_user.operates_in_area?(package.destination_area_id)
            'Delivery area rider'
          else
            'Area access'
          end
        when 'warehouse'
          'Warehouse processing'
        when 'admin'
          'Administrator access'
        else
          'Unknown access'
        end
      end

      def apply_filters(packages)
        packages = packages.where(state: params[:state]) if params[:state].present?
        packages = packages.where("code ILIKE ?", "%#{params[:search]}%") if params[:search].present?
        
        case current_user.primary_role
        when 'agent'
          if params[:area_filter] == 'origin'
            packages = packages.where(origin_area_id: current_user.accessible_areas)
          elsif params[:area_filter] == 'destination'
            packages = packages.where(destination_area_id: current_user.accessible_areas)
          end
        when 'rider'
          if params[:action_filter] == 'collection'
            packages = packages.where(origin_area_id: current_user.accessible_areas, state: 'submitted')
          elsif params[:action_filter] == 'delivery'
            packages = packages.where(destination_area_id: current_user.accessible_areas, state: 'in_transit')
          end
        end
        
        packages
      end

      def get_sender_phone(package)
        return package.sender_phone if package.respond_to?(:sender_phone) && package.sender_phone.present?
        return package.user&.phone if package.user&.phone.present?
        return nil
      end

      def get_sender_email(package)
        return package.sender_email if package.respond_to?(:sender_email) && package.sender_email.present?
        return package.user&.email if package.user&.email.present?
        return nil
      end

      def get_receiver_email(package)
        return package.receiver_email if package.respond_to?(:receiver_email) && package.receiver_email.present?
        return nil
      end

      def get_business_name(package)
        return package.business_name if package.respond_to?(:business_name) && package.business_name.present?
        return package.user&.business_name if package.user&.respond_to?(:business_name) && package.user&.business_name.present?
        return package.user&.company if package.user&.respond_to?(:company) && package.user&.company.present?
        return nil
      end

      # FIXED: Enhanced state validation with collected state
      def valid_state_transition?(current_state, new_state)
        valid_transitions = {
          'pending_unpaid' => ['pending', 'rejected'],
          'pending' => ['submitted', 'rejected'],
          'submitted' => ['in_transit', 'rejected'],
          'in_transit' => ['delivered', 'rejected'],
          'delivered' => ['collected', 'rejected'],  # FIXED: Added collected after delivered
          'collected' => [], # Final state
          'rejected' => ['pending'] # Can be resubmitted
        }

        return true if current_user.primary_role == 'admin'
        
        allowed_states = valid_transitions[current_state] || []
        is_valid = allowed_states.include?(new_state)
        
        Rails.logger.info "🔄 State transition validation: #{current_state} -> #{new_state}, valid: #{is_valid}"
        
        is_valid
      end

      def ensure_package_has_code(package)
        if package.code.blank?
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

      def serialize_area(area)
        return nil unless area
        
        {
          'id' => area.id.to_s,
          'name' => area.name,
          'location' => area.respond_to?(:location) ? serialize_location(area.location) : nil
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

      # FIXED: User serialization to handle missing name field
      def serialize_user_basic(user)
        return nil unless user
        
        # Build name from available fields
        name = if user.respond_to?(:name) && user.name.present?
          user.name
        elsif user.respond_to?(:first_name) && user.respond_to?(:last_name)
          "#{user.first_name} #{user.last_name}".strip
        elsif user.respond_to?(:first_name) && user.first_name.present?
          user.first_name
        elsif user.respond_to?(:last_name) && user.last_name.present?
          user.last_name
        else
          user.email # Fallback to email if no name fields
        end
        
        {
          'id' => user.id.to_s,
          'name' => name,
          'email' => user.email,
          'role' => user.primary_role
        }
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
                      :destination_area_id, :destination_agent_id, :delivery_type, :state]
        
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
          if package.respond_to?(:route_description)
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
    end
  end
end