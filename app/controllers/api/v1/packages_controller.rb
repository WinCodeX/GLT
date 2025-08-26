# app/controllers/api/v1/packages_controller.rb - Complete Fixed Version (Syntax Fixed)
module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_package, only: [:show, :update, :destroy, :qr_code, :tracking_page, :pay, :submit]
      before_action :set_package_for_authenticated_user, only: [:pay, :submit, :update, :destroy, :qr_code]
      before_action :force_json_format

      # ===========================================
      # 📋 MAIN ACTIONS
      # ===========================================

      def index
        begin
          Rails.logger.info "PackagesController#index called by user #{current_user.id} (#{current_user.primary_role})"
          
          packages = current_user.accessible_packages
                                .includes(:origin_area, :destination_area, :origin_agent, :destination_agent, 
                                         origin_area: :location, destination_area: :location, :user)
                                .order(created_at: :desc)
          
          Rails.logger.info "Found #{packages.count} accessible packages for user"
          
          packages = apply_filters(packages)
          
          page = [params[:page]&.to_i || 1, 1].max
          per_page = [[params[:per_page]&.to_i || 20, 1].max, 100].min
          
          total_count = packages.count
          packages = packages.offset((page - 1) * per_page).limit(per_page)

          serialized_packages = packages.map do |package|
            serialize_package_with_complete_info(package)
          end

          Rails.logger.info "Successfully serialized #{serialized_packages.length} packages"

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
          
          # Set area IDs from agent IDs before validation
          set_area_ids_from_agents(package)
          
          # Set initial state and generate metadata
          package.state = 'pending_unpaid'
          package.cost = calculate_package_cost(package)

          Rails.logger.info "Creating package with params: origin_area_id=#{package.origin_area_id}, destination_area_id=#{package.destination_area_id}"

          if package.save
            Rails.logger.info "Package created successfully: #{package.code}"
            render json: {
              success: true,
              data: serialize_package_complete(package),
              message: 'Package created successfully'
            }, status: :created
          else
            Rails.logger.error "Package creation failed: #{package.errors.full_messages}"
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

          if @package.update(package_update_params)
            render json: {
              success: true,
              data: serialize_package_complete(@package),
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
                                         origin_area: :location, destination_area: :location, :user)
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

      private

      # ===========================================
      # 🔧 HELPER METHODS
      # ===========================================

      def force_json_format
        request.format = :json
      end

      def set_package
        @package = Package.includes(
          :origin_area, :destination_area, :origin_agent, :destination_agent, :user,
          origin_area: :location,
          destination_area: :location
        ).find_by(code: params[:id])
        
        unless @package
          render json: { 
            success: false, 
            message: 'Package not found' 
          }, status: :not_found
          return
        end
        
        ensure_package_has_code(@package)
      end

      def set_package_for_authenticated_user
        @package = current_user.accessible_packages
                               .includes(:origin_area, :destination_area, :origin_agent, :destination_agent,
                                        origin_area: :location, destination_area: :location, :user)
                               .find_by(code: params[:id])
        
        unless @package
          render json: { 
            success: false, 
            message: 'Package not found or access denied' 
          }, status: :not_found
          return
        end
        
        ensure_package_has_code(@package)
      end

      def ensure_package_has_code(package)
        if package&.code.blank?
          package.update_column(:code, "PKG#{package.id.to_s.rjust(6, '0')}")
        end
      end

      # ===========================================
      # 🔒 PERMISSION METHODS
      # ===========================================

      def can_edit_package?(package)
        case current_user.primary_role
        when 'client'
          package.user == current_user && ['pending_unpaid', 'pending'].include?(package.state)
        when 'admin'
          true
        when 'agent', 'rider', 'warehouse'
          current_user.can_access_package?(package)
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

      # ===========================================
      # 📊 SERIALIZATION METHODS
      # ===========================================

      def serialize_package_basic(package)
        {
          id: package.id.to_s,
          code: package.code || "PKG#{package.id.to_s.rjust(6, '0')}",
          state: package.state,
          state_display: package.state&.humanize || 'Unknown',
          delivery_type: package.delivery_type,
          delivery_type_display: package.delivery_type&.humanize || 'Standard',
          cost: package.cost.to_f,
          sender_name: package.sender_name,
          receiver_name: package.receiver_name,
          created_at: package.created_at,
          updated_at: package.updated_at,
          route_sequence: package.respond_to?(:route_sequence) ? package.route_sequence : nil,
          intra_area: package.respond_to?(:intra_area_shipment?) ? package.intra_area_shipment? : false,
          is_paid: package.state != 'pending_unpaid'
        }
      end

      def serialize_package_with_complete_info(package)
        data = serialize_package_basic(package)
        
        additional_info = {
          sender_phone: get_sender_phone(package),
          sender_email: get_sender_email(package),
          receiver_email: get_receiver_email(package),
          receiver_phone: package.receiver_phone,
          business_name: get_business_name(package),
          delivery_location: package.respond_to?(:delivery_location) ? package.delivery_location : nil,
          origin_area: serialize_area(package.origin_area),
          destination_area: serialize_area(package.destination_area)
        }
        
        data.merge!(additional_info)
        
        unless current_user.client?
          staff_info = {
            access_reason: get_access_reason(package),
            user_can_scan: current_user.can_scan_packages?,
            available_actions: get_available_scanning_actions(package).map { |a| a[:action] }
          }
          data.merge!(staff_info)
        end
        
        data
      end

      def serialize_package_complete(package)
        data = serialize_package_basic(package)
        
        complete_info = {
          sender_phone: get_sender_phone(package),
          sender_email: get_sender_email(package),
          receiver_email: get_receiver_email(package),
          receiver_phone: package.receiver_phone,
          business_name: get_business_name(package),
          origin_area: serialize_area(package.origin_area),
          destination_area: serialize_area(package.destination_area),
          origin_agent: serialize_agent(package.origin_agent),
          destination_agent: serialize_agent(package.destination_agent),
          delivery_location: package.respond_to?(:delivery_location) ? package.delivery_location : nil,
          tracking_url: package_tracking_url(package.code),
          created_by: serialize_user_basic(package.user),
          is_editable: can_edit_package?(package),
          is_deletable: can_delete_package?(package),
          available_scanning_actions: get_available_scanning_actions(package)
        }
        
        data.merge!(complete_info)
        data
      end

      def serialize_area(area)
        return nil unless area
        
        location_data = if area.location
          {
            id: area.location.id.to_s,
            name: area.location.name,
            initials: area.location.respond_to?(:initials) ? area.location.initials : nil
          }
        else
          nil
        end
        
        {
          id: area.id.to_s,
          name: area.name,
          initials: area.initials,
          location: location_data
        }
      end

      def serialize_agent(agent)
        return nil unless agent
        
        {
          id: agent.id.to_s,
          name: agent.name,
          phone: agent.phone,
          active: agent.respond_to?(:active) ? agent.active : true,
          area: agent.respond_to?(:area) ? serialize_area(agent.area) : nil
        }
      end

      def serialize_user_basic(user)
        return nil unless user
        
        name = if user.respond_to?(:display_name) && user.display_name.present?
          user.display_name
        elsif user.respond_to?(:full_name) && user.full_name.present?
          user.full_name
        elsif user.respond_to?(:first_name) && user.respond_to?(:last_name)
          "#{user.first_name} #{user.last_name}".strip
        elsif user.respond_to?(:first_name) && user.first_name.present?
          user.first_name
        else
          user.email
        end
        
        {
          id: user.id.to_s,
          name: name,
          email: user.email,
          role: user.respond_to?(:primary_role) ? user.primary_role : 'client'
        }
      end

      # ===========================================
      # 🔍 FILTERING METHODS
      # ===========================================

      def apply_filters(packages)
        packages = packages.where(state: params[:state]) if params[:state].present?
        packages = packages.where("code ILIKE ?", "%#{params[:search]}%") if params[:search].present?
        
        case current_user.primary_role
        when 'agent'
          if params[:area_filter] == 'origin'
            area_ids = current_user.accessible_areas.pluck(:id)
            packages = packages.where(origin_area_id: area_ids) if area_ids.any?
          elsif params[:area_filter] == 'destination'
            area_ids = current_user.accessible_areas.pluck(:id)
            packages = packages.where(destination_area_id: area_ids) if area_ids.any?
          end
        when 'rider'
          area_ids = current_user.accessible_areas.pluck(:id)
          if area_ids.any?
            if params[:action_filter] == 'collection'
              packages = packages.where(origin_area_id: area_ids, state: 'submitted')
            elsif params[:action_filter] == 'delivery'
              packages = packages.where(destination_area_id: area_ids, state: 'in_transit')
            end
          end
        end
        
        packages
      end

      # ===========================================
      # 📋 DATA EXTRACTION METHODS
      # ===========================================

      def get_sender_phone(package)
        return package.sender_phone if package.respond_to?(:sender_phone) && package.sender_phone.present?
        return package.user&.phone_number if package.user&.respond_to?(:phone_number) && package.user.phone_number.present?
        return package.user&.phone if package.user&.respond_to?(:phone) && package.user.phone.present?
        nil
      end

      def get_sender_email(package)
        return package.sender_email if package.respond_to?(:sender_email) && package.sender_email.present?
        return package.user&.email if package.user&.email.present?
        nil
      end

      def get_receiver_email(package)
        return package.receiver_email if package.respond_to?(:receiver_email) && package.receiver_email.present?
        nil
      end

      def get_business_name(package)
        return package.business_name if package.respond_to?(:business_name) && package.business_name.present?
        nil
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
          'Standard access'
        end
      end

      # ===========================================
      # 🔧 SCANNING ACTIONS
      # ===========================================

      def get_available_scanning_actions(package)
        return [] unless current_user.can_scan_packages?
        
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

      # ===========================================
      # 🔧 UTILITY METHODS
      # ===========================================

      def package_tracking_url(code)
        if Rails.env.production?
          "https://glt-53x8.onrender.com/track/#{code}"
        else
          "http://#{request.host}:#{request.port}/track/#{code}"
        end
      end

      def set_area_ids_from_agents(package)
        if package.origin_agent_id.present? && package.origin_area_id.blank?
          agent = Agent.find_by(id: package.origin_agent_id)
          package.origin_area_id = agent&.area_id
        end

        if package.destination_agent_id.present? && package.destination_area_id.blank?
          agent = Agent.find_by(id: package.destination_agent_id)
          package.destination_area_id = agent&.area_id
        end
      end

      def calculate_package_cost(package)
        base_cost = 100.0
        
        if package.origin_area_id == package.destination_area_id
          base_cost
        else
          base_cost * 1.5
        end
      end

      # ===========================================
      # 📋 PARAMETER METHODS
      # ===========================================

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
          unless valid_state_transition?(@package.state, filtered_params[:state])
            filtered_params.delete(:state)
          end
        end
        
        filtered_params
      end

      def valid_state_transition?(current_state, new_state)
        valid_transitions = {
          'pending_unpaid' => ['pending', 'rejected'],
          'pending' => ['submitted', 'rejected'],
          'submitted' => ['in_transit', 'rejected'],
          'in_transit' => ['delivered', 'rejected'],
          'delivered' => ['collected'],
          'collected' => [],
          'rejected' => []
        }
        
        valid_transitions[current_state]&.include?(new_state) || false
      end
    end
  end
end