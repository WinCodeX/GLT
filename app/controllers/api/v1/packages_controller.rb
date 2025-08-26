# app/controllers/api/v1/packages_controller.rb - UPDATED: Origin agent is optional
module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!
      before_action :force_json_format
      before_action :set_package, only: [:show, :update, :destroy, :submit]

      def index
        begin
          # Enhanced filtering and sorting
          packages = current_user.packages.includes(:origin_area, :destination_area, :origin_agent, :destination_agent)
          
          # Apply filters
          packages = packages.where(state: params[:state]) if params[:state].present?
          packages = packages.where(delivery_type: params[:delivery_type]) if params[:delivery_type].present?
          
          # Apply search
          if params[:search].present?
            search_term = "%#{params[:search]}%"
            packages = packages.where(
              "code ILIKE ? OR receiver_name ILIKE ? OR sender_name ILIKE ?", 
              search_term, search_term, search_term
            )
          end
          
          # Sorting
          sort_order = params[:sort_order] == 'asc' ? 'asc' : 'desc'
          case params[:sort_by]
          when 'created_at'
            packages = packages.order(created_at: sort_order)
          when 'state'
            packages = packages.order(state: sort_order)
          when 'delivery_type'
            packages = packages.order(delivery_type: sort_order)
          else
            packages = packages.order(created_at: :desc)
          end
          
          # Pagination
          page = [params[:page].to_i, 1].max
          per_page = [params[:per_page]&.to_i || 20, 100].min
          packages = packages.page(page).per(per_page)
          
          render json: {
            success: true,
            data: packages.map { |pkg| serialize_package_basic(pkg) },
            pagination: {
              current_page: packages.current_page,
              per_page: packages.limit_value,
              total_pages: packages.total_pages,
              total_count: packages.total_count
            }
          }
        rescue => e
          Rails.logger.error "PackagesController#index error: #{e.message}"
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

      # UPDATED: Create method - origin agent is optional
      def create
        unless current_user.client?
          return render json: {
            success: false,
            message: 'Only customers can create packages'
          }, status: :forbidden
        end

        begin
          # Build package with permitted parameters
          package = current_user.packages.build(package_params)
          
          # UPDATED: Set area IDs from agent IDs if agents are provided (origin agent is optional)
          set_area_ids_from_agents(package) if package.origin_agent_id.present? || package.destination_agent_id.present?
          
          # Set initial state
          package.state = 'pending_unpaid'
          
          # Generate package code and cost after validation
          if package.valid?
            package.code = generate_package_code(package) if package.code.blank?
            package.cost = calculate_package_cost(package) if package.cost.blank?
          end

          Rails.logger.info "🆕 Creating package: delivery_type=#{package.delivery_type}, destination_area_id=#{package.destination_area_id}, destination_agent_id=#{package.destination_agent_id}"

          if package.save
            Rails.logger.info "✅ Package created successfully: #{package.code}"
            render json: {
              success: true,
              data: serialize_package_complete(package),
              message: 'Package created successfully'
            }, status: :created
          else
            Rails.logger.error "❌ Package creation failed: #{package.errors.full_messages}"
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
        unless current_user.can_access_package?(@package)
          return render json: {
            success: false,
            message: 'Access denied to this package'
          }, status: :forbidden
        end

        begin
          filtered_params = package_update_params
          
          # UPDATED: Only set area IDs if agent IDs are being updated
          if filtered_params[:origin_agent_id].present? || filtered_params[:destination_agent_id].present?
            set_area_ids_from_agents(@package, filtered_params)
          end

          if @package.update(filtered_params)
            Rails.logger.info "✅ Package updated: #{@package.code}"
            render json: {
              success: true,
              data: serialize_package_complete(@package),
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
        unless current_user.can_delete_package?(@package)
          return render json: {
            success: false,
            message: 'You do not have permission to delete this package'
          }, status: :forbidden
        end

        begin
          @package.destroy!
          render json: { 
            success: true, 
            message: 'Package deleted successfully' 
          }
        rescue => e
          Rails.logger.error "PackagesController#destroy error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Package deletion failed',
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

      # UPDATED: Modified to handle optional agent associations
      def set_area_ids_from_agents(package, params_override = nil)
        params_to_use = params_override || package.attributes.symbolize_keys

        # Set origin_area_id from origin_agent_id if provided
        if params_to_use[:origin_agent_id].present?
          begin
            origin_agent = Agent.find(params_to_use[:origin_agent_id])
            package.origin_area_id = origin_agent.area_id
            Rails.logger.info "📍 Set origin_area_id=#{package.origin_area_id} from origin_agent_id=#{params_to_use[:origin_agent_id]}"
          rescue ActiveRecord::RecordNotFound
            Rails.logger.error "❌ Origin agent not found: #{params_to_use[:origin_agent_id]}"
            # Don't fail here, validation will handle if required
          end
        end

        # Set destination_area_id from destination_agent_id if provided and destination_area_id not already set
        if params_to_use[:destination_agent_id].present? && package.destination_area_id.blank?
          begin
            destination_agent = Agent.find(params_to_use[:destination_agent_id])
            package.destination_area_id = destination_agent.area_id
            Rails.logger.info "📍 Set destination_area_id=#{package.destination_area_id} from destination_agent_id=#{params_to_use[:destination_agent_id]}"
          rescue ActiveRecord::RecordNotFound
            Rails.logger.error "❌ Destination agent not found: #{params_to_use[:destination_agent_id]}"
            # Don't fail here, validation will handle if required
          end
        end
      end

      def force_json_format
        request.format = :json
      end

      def set_package
        @package = Package.find_by!(code: params[:id]) || Package.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: {
          success: false,
          message: 'Package not found'
        }, status: :not_found
      end

      # UPDATED: Package params - origin_agent_id is optional
      def package_params
        base_params = [
          :sender_name, :sender_phone, :receiver_name, :receiver_phone,
          :destination_area_id, :destination_agent_id, :delivery_type, :delivery_location
        ]
        
        # Include origin agent as optional
        base_params << :origin_agent_id
        base_params << :origin_area_id
        
        # Include collection service fields
        collection_fields = [
          :shop_name, :shop_contact, :collection_address, :items_to_collect, :item_value,
          :payment_method, :special_instructions, :priority_level, :special_handling,
          :requires_payment_advance, :collection_type, :item_description
        ]
        
        # Include location coordinates
        location_fields = [
          :pickup_latitude, :pickup_longitude, :delivery_latitude, :delivery_longitude
        ]
        
        # Include timestamps
        timestamp_fields = [
          :payment_deadline, :collection_scheduled_at
        ]
        
        # Add optional fields that exist in the model
        optional_fields = collection_fields + location_fields + timestamp_fields + 
                         [:sender_email, :receiver_email, :business_name]
        
        optional_fields.each do |field|
          base_params << field if Package.column_names.include?(field.to_s)
        end
        
        params.require(:package).permit(*base_params)
      end

      def package_update_params
        base_params = [:sender_name, :sender_phone, :receiver_name, :receiver_phone, 
                      :destination_area_id, :destination_agent_id, :delivery_type, :state,
                      :origin_agent_id, :origin_area_id, :delivery_location]
        
        # Include collection service fields for updates
        collection_fields = [
          :shop_name, :shop_contact, :collection_address, :items_to_collect, :item_value,
          :payment_method, :special_instructions, :priority_level, :special_handling,
          :requires_payment_advance, :collection_type, :item_description
        ]
        
        optional_fields = collection_fields + [:sender_email, :receiver_email, :business_name]
        optional_fields.each do |field|
          base_params << field if Package.column_names.include?(field.to_s)
        end
        
        permitted_params = []
        
        case current_user.primary_role
        when 'client'
          if ['pending_unpaid', 'pending'].include?(@package.state)
            permitted_params = [:sender_name, :sender_phone, :receiver_name, :receiver_phone, 
                               :destination_area_id, :destination_agent_id, :delivery_location,
                               :sender_email, :receiver_email, :business_name] + collection_fields
            permitted_params.select! { |field| base_params.include?(field) }
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
            raise StandardError.new("Invalid state transition from #{@package.state} to #{filtered_params[:state]}")
          end
        end
        
        filtered_params
      end

      def serialize_package_basic(package)
        {
          'id' => package.id.to_s,
          'code' => package.code,
          'sender_name' => package.sender_name,
          'sender_phone' => package.sender_phone,
          'receiver_name' => package.receiver_name,
          'receiver_phone' => package.receiver_phone,
          'delivery_type' => package.delivery_type,
          'state' => package.state,
          'display_status' => package.display_status,
          'cost' => package.cost,
          'created_at' => package.created_at,
          'updated_at' => package.updated_at,
          'estimated_delivery' => package.estimated_delivery_time,
          'route' => package.display_route,
          'is_collection_service' => package.is_collection_service?,
          'requires_payment' => package.requires_payment?
        }
      end

      def serialize_package_complete(package)
        basic_data = serialize_package_basic(package)
        
        basic_data.merge!(
          'delivery_location' => package.delivery_location,
          'origin_area' => package.origin_area ? serialize_area(package.origin_area) : nil,
          'destination_area' => package.destination_area ? serialize_area(package.destination_area) : nil,
          'origin_agent' => package.origin_agent ? serialize_agent(package.origin_agent) : nil,
          'destination_agent' => package.destination_agent ? serialize_agent(package.destination_agent) : nil,
          'user' => serialize_user_basic(package.user),
          'route_sequence' => package.route_sequence,
          'sender_email' => get_sender_email(package),
          'receiver_email' => get_receiver_email(package),
          'business_name' => get_business_name(package)
        )
        
        # Add collection service fields if present
        if package.is_collection_service?
          basic_data.merge!(
            'shop_name' => package.shop_name,
            'shop_contact' => package.shop_contact,
            'collection_address' => package.collection_address,
            'items_to_collect' => package.items_to_collect,
            'item_value' => package.item_value,
            'collection_type' => package.collection_type,
            'requires_payment_advance' => package.requires_payment_advance?
          )
        end
        
        # Add additional optional fields if present
        optional_fields = {
          'item_description' => package.try(:item_description),
          'special_instructions' => package.try(:special_instructions),
          'payment_method' => package.try(:payment_method),
          'payment_status' => package.try(:payment_status),
          'priority_level' => package.try(:priority_level),
          'special_handling' => package.try(:special_handling),
          'payment_pending' => package.respond_to?(:payment_pending?) ? package.payment_pending? : nil,
          'payment_completed' => package.respond_to?(:payment_completed?) ? package.payment_completed? : nil,
          'high_priority' => package.respond_to?(:high_priority?) ? package.high_priority? : nil,
          'urgent_priority' => package.respond_to?(:urgent_priority?) ? package.urgent_priority? : nil
        }
        
        optional_fields.each do |key, value|
          basic_data[key] = value if value.present?
        end
        
        basic_data
      end

      def serialize_area(area)
        return nil unless area
        
        {
          'id' => area.id.to_s,
          'name' => area.name,
          'initials' => area.safe_initials,
          'location' => area.location ? serialize_location(area.location) : nil
        }
      end

      def serialize_location(location)
        return nil unless location
        
        {
          'id' => location.id.to_s,
          'name' => location.name,
          'initials' => location.safe_initials
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

      def valid_state_transition?(current_state, new_state)
        valid_transitions = {
          'pending_unpaid' => ['pending', 'rejected'],
          'pending' => ['submitted', 'rejected'],
          'submitted' => ['in_transit', 'rejected'],
          'in_transit' => ['delivered', 'rejected'],
          'delivered' => ['collected', 'rejected'],
          'collected' => [], # Final state
          'rejected' => ['pending'] # Can be resubmitted
        }

        return true if current_user.primary_role == 'admin'
        
        allowed_states = valid_transitions[current_state] || []
        is_valid = allowed_states.include?(new_state)
        
        Rails.logger.info "🔄 State transition validation: #{current_state} -> #{new_state}, valid: #{is_valid}"
        
        is_valid
      end

      def generate_package_code(package)
        # Use the package's own method if available
        return package.send(:generate_unique_code) if package.respond_to?(:generate_unique_code, true)
        
        # Fallback code generation
        prefix = case package.delivery_type
        when 'fragile' then 'FRG'
        when 'agent' then 'AGT'  
        when 'doorstep' then 'DST'
        else 'PKG'
        end
        
        prefix = "COL-#{prefix}" if package.collection_type.present?
        
        "#{prefix}-#{Time.current.strftime('%Y%m%d')}-#{SecureRandom.hex(2).upcase}"
      end

      def calculate_package_cost(package)
        # Use the package's own calculation method if available
        return package.send(:calculate_cost) if package.respond_to?(:calculate_cost, true)
        
        # Fallback cost calculation
        base_cost = case package.delivery_type
        when 'fragile' then 300
        when 'agent' then 150
        when 'doorstep' then 200
        else 200
        end
        
        # Add collection service cost
        base_cost += 150 if package.collection_type == 'pickup_and_deliver'
        
        # Add priority surcharge
        if package.respond_to?(:high_priority?) && package.high_priority?
          base_cost += 50
        elsif package.respond_to?(:urgent_priority?) && package.urgent_priority?
          base_cost += 100
        end
        
        base_cost
      end

      def can_edit_package?(package)
        return false unless current_user.can_access_package?(package)
        return true if current_user.admin?
        return package.can_be_edited? if current_user.client?
        false
      end

      def can_delete_package?(package)
        return false unless current_user.can_access_package?(package)
        return true if current_user.admin?
        return package.can_be_cancelled? if current_user.client?
        false
      end

      def get_available_scanning_actions(package)
        # Return available scanning actions based on user role and package state
        actions = []
        
        case current_user.primary_role
        when 'admin'
          actions = ['pickup', 'transit', 'deliver', 'collect']
        when 'agent'
          actions = package.state == 'submitted' ? ['pickup'] : []
          actions << 'deliver' if package.state == 'in_transit' && package.destination_agent_id == current_user.id
        when 'rider'
          actions = ['transit', 'deliver'] if ['submitted', 'in_transit'].include?(package.state)
        end
        
        actions
      end
    end
  end
end