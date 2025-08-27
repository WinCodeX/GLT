# app/controllers/api/v1/packages_controller.rb - SIMPLIFIED AND FIXED
module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_package, only: [:show, :qr_code, :thermal_qr_code, :qr_comparison]
      before_action :force_json_format

      def index
        begin
          Rails.logger.info "PackagesController#index - User: #{current_user.email}, Role: #{current_user.primary_role}"
          Rails.logger.info "Request params: #{params.to_unsafe_h.slice(:state, :search, :page, :per_page, :area_filter, :action_filter)}"
          
          # Start with accessible packages
          packages = current_user.accessible_packages
                                .includes(:origin_area, :destination_area, :origin_agent, :destination_agent, 
                                         origin_area: :location, destination_area: :location)
                                .order(created_at: :desc)
          
          Rails.logger.info "Base packages count: #{packages.count}"
          
          # Apply filters with proper precedence
          packages = apply_filters(packages)
          
          Rails.logger.info "After filtering count: #{packages.count}"
          
          # Pagination
          page = [params[:page]&.to_i || 1, 1].max
          per_page = [[params[:per_page]&.to_i || 20, 1].max, 100].min
          
          total_count = packages.count
          packages = packages.offset((page - 1) * per_page).limit(per_page)

          serialized_packages = packages.map do |package|
            serialize_package_with_complete_info(package)
          end

          # Validate state filtering worked
          if params[:state].present?
            returned_states = serialized_packages.map { |p| p['state'] }.uniq
            if returned_states != [params[:state]]
              Rails.logger.error "STATE FILTERING FAILED! Expected: #{params[:state]}, Got: #{returned_states}"
            else
              Rails.logger.info "State filtering successful for state: #{params[:state]}"
            end
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
              can_scan: current_user.respond_to?(:can_scan_packages?) ? current_user.can_scan_packages? : false,
              access_reason: get_access_reason(@package)
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

      def qr_code
        begin
          Rails.logger.info "Generating QR code for package: #{@package.code}"
          
          if defined?(QrCodeGenerator)
            qr_options = {
              module_size: params[:module_size]&.to_i || 8,
              border_size: params[:border_size]&.to_i || 20,
              corner_radius: params[:corner_radius]&.to_i || 5,
              data_type: params[:data_type]&.to_sym || :url,
              center_logo: params[:center_logo] != 'false',
              gradient: params[:gradient] != 'false'
            }
            
            qr_generator = QrCodeGenerator.new(@package, qr_options)
            qr_base64 = qr_generator.generate_base64
            
            render json: {
              success: true,
              data: {
                qr_code_base64: qr_base64,
                tracking_url: package_tracking_url(@package.code),
                package_code: @package.code,
                package_state: @package.state,
                route_description: safe_route_description(@package),
                qr_type: 'organic',
                generated_at: Time.current.iso8601
              },
              message: 'QR code generated successfully'
            }
          else
            render json: {
              success: false,
              message: 'QR code generation service not available',
              data: {
                tracking_url: package_tracking_url(@package.code),
                package_code: @package.code
              }
            }, status: :service_unavailable
          end
        rescue => e
          Rails.logger.error "QR code generation failed: #{e.message}"
          render json: {
            success: false,
            message: 'QR code generation failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def thermal_qr_code
        begin
          Rails.logger.info "Generating thermal QR code for package: #{@package.code}"
          
          if defined?(ThermalQrGenerator)
            thermal_options = {
              module_size: params[:module_size]&.to_i || 6,
              border_size: params[:border_size]&.to_i || 12,
              corner_radius: params[:corner_radius]&.to_i || 3,
              data_type: params[:data_type]&.to_sym || :url
            }
            
            thermal_generator = ThermalQrGenerator.new(@package, thermal_options)
            render json: thermal_generator.generate_thermal_response
          else
            render json: {
              success: false,
              message: 'Thermal QR code generation service not available'
            }, status: :service_unavailable
          end
        rescue => e
          Rails.logger.error "Thermal QR code generation failed: #{e.message}"
          render json: {
            success: false,
            message: 'Thermal QR code generation failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def qr_comparison
        begin
          if @package.respond_to?(:qr_code_comparison)
            render json: {
              success: true,
              data: @package.qr_code_comparison(include_images: params[:include_images] == 'true')
            }
          else
            render json: {
              success: false,
              message: 'QR code comparison not available for this package'
            }, status: :not_implemented
          end
        rescue => e
          Rails.logger.error "QR code comparison failed: #{e.message}"
          render json: {
            success: false,
            message: 'QR code comparison failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      private

      def force_json_format
        request.format = :json
      end

      def apply_filters(packages)
        # Apply explicit filters first
        packages = packages.where(state: params[:state]) if params[:state].present?
        packages = packages.where("code ILIKE ?", "%#{params[:search]}%") if params[:search].present?
        
        # Apply role-based filters
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
              # Only apply default state if no explicit state was provided
              packages = packages.where(state: 'submitted') if params[:state].blank?
            elsif params[:action_filter] == 'delivery'
              packages = packages.where(destination_area_id: current_user.accessible_areas)
              # Only apply default state if no explicit state was provided
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

      def set_package
        @package = Package.includes(:origin_area, :destination_area, :origin_agent, :destination_agent,
                                   origin_area: :location, destination_area: :location)
                         .find_by!(code: params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: 'Package not found' 
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
          'delivery_location' => package.respond_to?(:delivery_location) ? package.delivery_location : nil,
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
          'delivery_location' => package.respond_to?(:delivery_location) ? package.delivery_location : nil,
          'tracking_url' => package_tracking_url(package.code),
          'created_by' => serialize_user_basic(package.user),
          'is_editable' => can_edit_package?(package),
          'is_deletable' => can_delete_package?(package),
          'available_scanning_actions' => get_available_scanning_actions(package)
        }
        
        data.merge!(additional_data)
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
          'role' => user.respond_to?(:primary_role) ? user.primary_role : 'user'
        }
      end

      def get_sender_phone(package)
        return package.sender_phone if package.respond_to?(:sender_phone) && package.sender_phone.present?
        return package.user&.phone if package.user&.phone.present?
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

      def safe_route_description(package)
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
      end

      def package_tracking_url(code)
        begin
          Rails.application.routes.url_helpers.tracking_url(code)
        rescue
          protocol = Rails.env.production? ? 'https' : 'http'
          host = Rails.application.config.action_mailer.default_url_options[:host] || 
                 ENV['APP_URL']&.sub(/^https?:\/\//, '') || 'localhost:3000'
          "#{protocol}://#{host}/track/#{code}"
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