module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_package, only: [:show, :update, :destroy, :qr_code, :tracking_page, :pay, :submit]
      before_action :set_package_for_authenticated_user, only: [:pay, :submit, :update, :destroy, :qr_code]
      before_action :force_json_format

      def index
        # Add safety check for packages association
        unless current_user.respond_to?(:packages)
          return render json: { 
            success: false, 
            message: 'User packages association not found' 
          }, status: :internal_server_error
        end

        packages = current_user.packages
                              .includes(:origin_area, :destination_area, :origin_agent, :destination_agent)
                              .order(created_at: :desc)
        
        packages = apply_filters(packages)
        
        # Pagination with better defaults
        page = [params[:page]&.to_i || 1, 1].max
        per_page = [[params[:per_page]&.to_i || 20, 1].max, 100].min
        
        total_count = packages.count
        packages = packages.offset((page - 1) * per_page).limit(per_page)

        begin
          # Simplified serialization to avoid FastJSONAPI issues
          serialized_packages = packages.map do |package|
            serialize_package_basic(package)
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
          render json: {
            success: true,
            data: serialize_package_detailed(@package)
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
        # Add safety check for packages association
        unless current_user.respond_to?(:packages)
          return render json: { 
            success: false, 
            message: 'User packages association not found' 
          }, status: :internal_server_error
        end

        begin
          package = current_user.packages.build(package_params)
          package.state = 'pending_unpaid'
          
          # Generate package code with better error handling
          package.code = generate_package_code(package)
          
          # Calculate cost with fallback
          package.cost = calculate_package_cost(package)

          if package.save
            render json: {
              success: true,
              data: serialize_package_detailed(package),
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
          if @package.update(package_update_params)
            # Recalculate cost if relevant fields changed
            if should_recalculate_cost?(package_update_params)
              new_cost = calculate_package_cost(@package)
              @package.update_column(:cost, new_cost) if new_cost
            end

            render json: {
              success: true,
              data: serialize_package_detailed(@package),
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
          unless @package.user == current_user
            return render json: { 
              success: false, 
              message: 'Access denied' 
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
            data: serialize_package_detailed(@package),
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

      def search
        query = params[:query]&.strip
        
        if query.blank?
          return render json: { 
            success: false, 
            message: 'Search query is required' 
          }, status: :bad_request
        end

        # Add safety check for packages association
        unless current_user.respond_to?(:packages)
          return render json: { 
            success: false, 
            message: 'User packages association not found' 
          }, status: :internal_server_error
        end

        begin
          packages = current_user.packages
                                .includes(:origin_area, :destination_area)
                                .where("code ILIKE ?", "%#{query}%")
                                .limit(20)

          serialized_packages = packages.map do |package|
            serialize_package_search(package)
          end

          render json: {
            success: true,
            data: serialized_packages,
            query: query,
            count: serialized_packages.length
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
        # Add safety check for packages association
        unless current_user.respond_to?(:packages)
          return render json: { 
            success: false, 
            message: 'User packages association not found' 
          }, status: :internal_server_error
        end

        @package = current_user.packages.find_by!(code: params[:id])
        ensure_package_has_code(@package)
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: 'Package not found or access denied' 
        }, status: :not_found
      end

      def ensure_package_has_code(package)
        if package.code.blank?
          package.update!(code: generate_package_code(package))
        end
      rescue => e
        Rails.logger.error "Failed to ensure package code: #{e.message}"
      end

      def generate_package_code(package)
        # Try using PackageCodeGenerator service if available
        if defined?(PackageCodeGenerator)
          begin
            code_generator = PackageCodeGenerator.new(package)
            return code_generator.generate
          rescue => e
            Rails.logger.warn "PackageCodeGenerator failed: #{e.message}"
          end
        end
        
        # Fallback code generation
        "PKG-#{SecureRandom.hex(4).upcase}-#{Time.current.strftime('%Y%m%d')}"
      end

      def calculate_package_cost(package)
        # Try using package's own method if available
        if package.respond_to?(:calculate_delivery_cost)
          begin
            return package.calculate_delivery_cost
          rescue => e
            Rails.logger.warn "Package cost calculation method failed: #{e.message}"
          end
        end
        
        # Location-aware fallback cost calculation
        base_cost = 150
        
        case package.delivery_type
        when 'doorstep'
          base_cost += 100
        when 'agent'
          base_cost += 0
        when 'mixed'
          base_cost += 50
        end

        # Use location-based pricing if available
        origin_location_id = package.origin_area&.location&.id
        destination_location_id = package.destination_area&.location&.id
        
        if origin_location_id && destination_location_id
          if origin_location_id != destination_location_id
            # Inter-location delivery (e.g., Nairobi to Kisumu)
            base_cost += 200
          else
            # Intra-location delivery (e.g., CBD to Kasarani within Nairobi)
            base_cost += 50
          end
        else
          # Fallback to area-based pricing
          if package.origin_area_id != package.destination_area_id
            base_cost += 100
          end
        end

        base_cost
      rescue => e
        Rails.logger.error "Cost calculation failed: #{e.message}"
        200 # Ultimate fallback
      end

      def should_recalculate_cost?(params)
        cost_affecting_fields = ['origin_area_id', 'destination_area_id', 'delivery_type']
        params.keys.any? { |key| cost_affecting_fields.include?(key) }
      end

      def generate_qr_code_data(package)
        tracking_url = package_tracking_url(package.code)
        
        # Try using QrCodeGenerator service if available
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
        
        # Fallback: return tracking URL only
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

      # Serialization methods to replace FastJSONAPI
      def serialize_package_basic(package)
        {
          id: package.id.to_s,
          code: package.code,
          state: package.state,
          state_display: package.state&.humanize,
          sender_name: package.sender_name,
          receiver_name: package.receiver_name,
          cost: package.cost,
          delivery_type: package.delivery_type,
          route_description: safe_route_description(package),
          created_at: package.created_at&.iso8601,
          updated_at: package.updated_at&.iso8601
        }
      end

      def serialize_package_detailed(package)
        data = serialize_package_basic(package)
        
        # Add detailed information
        data.merge!({
          sender_phone: package.sender_phone,
          receiver_phone: package.receiver_phone,
          delivery_location: package.delivery_location,
          origin_area: serialize_area(package.origin_area),
          destination_area: serialize_area(package.destination_area),
          origin_agent: serialize_agent(package.origin_agent),
          destination_agent: serialize_agent(package.destination_agent)
        })
        
        data
      end

      def serialize_package_search(package)
        {
          id: package.id.to_s,
          code: package.code,
          state: package.state,
          state_display: package.state&.humanize,
          route_description: safe_route_description(package),
          created_at: package.created_at&.iso8601
        }
      end

      def serialize_area(area)
        return nil unless area
        
        {
          id: area.id.to_s,
          name: area.name,
          location: area.respond_to?(:location) ? serialize_location(area.location) : nil
        }
      end

      def serialize_location(location)
        return nil unless location
        
        {
          id: location.id.to_s,
          name: location.name
        }
      end

      def serialize_agent(agent)
        return nil unless agent
        
        {
          id: agent.id.to_s,
          name: agent.name,
          phone: agent.phone
        }
      end

      def package_params
        params.require(:package).permit(
          :sender_name, :sender_phone, :receiver_name, :receiver_phone,
          :origin_area_id, :destination_area_id, :origin_agent_id, :destination_agent_id,
          :delivery_type, :delivery_location
        )
      end

      def package_update_params
        params.require(:package).permit(
          :receiver_name, :receiver_phone, :destination_area_id, 
          :destination_agent_id, :delivery_type, :delivery_location
        )
      end

      def apply_filters(packages)
        packages = packages.where(state: params[:state]) if params[:state].present?
        packages = packages.where("code ILIKE ?", "%#{params[:search]}%") if params[:search].present?
        packages
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
            # Updated: Use location-based route description to match generator logic
            origin_location = package.origin_area&.location&.name || 'Unknown Origin'
            destination_location = package.destination_area&.location&.name || 'Unknown Destination'
            
            # Show detailed area info only if different locations
            if package.origin_area&.location&.id == package.destination_area&.location&.id
              # Same location: show "Nairobi (CBD → Kasarani)"
              origin_area = package.origin_area&.name || 'Unknown Area'
              destination_area = package.destination_area&.name || 'Unknown Area'
              "#{origin_location} (#{origin_area} → #{destination_area})"
            else
              # Different locations: show "Nairobi → Kisumu"
              "#{origin_location} → #{destination_location}"
            end
          end
        rescue => e
          Rails.logger.error "Route description generation failed: #{e.message}"
          # Fallback to simple area-based description
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
        when 'cancelled'
          'Package delivery cancelled'
        else
          state&.humanize || 'Unknown status'
        end
      end
    end
  end
end