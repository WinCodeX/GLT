module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_package, only: [:show, :update, :destroy, :qr_code, :tracking_page, :pay, :submit]
      before_action :set_package_for_authenticated_user, only: [:pay, :submit, :update, :destroy, :qr_code] # Added qr_code
      before_action :force_json_format

      def index
        packages = current_user.packages
                              .includes(:origin_area, :destination_area, :origin_agent, :destination_agent)
                              .order(created_at: :desc)
        
        packages = apply_filters(packages)
        
        # Pagination
        page = params[:page]&.to_i || 1
        per_page = params[:per_page]&.to_i || 20
        per_page = [per_page, 100].min
        
        total_count = packages.count
        packages = packages.offset((page - 1) * per_page).limit(per_page)

        begin
          serialized_packages = PackageSerializer.new(
            packages, 
            include: ['origin_area', 'destination_area', 'origin_agent', 'destination_agent', 'origin_area.location', 'destination_area.location']
          ).serialized_json

          render json: {
            success: true,
            data: JSON.parse(serialized_packages),
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
          Rails.logger.error "PackagesController#index serialization error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load packages' 
          }, status: :internal_server_error
        end
      end

      def show
        begin
          render json: {
            success: true,
            data: JSON.parse(PackageSerializer.new(
              @package,
              include: ['origin_area', 'destination_area', 'origin_agent', 'destination_agent', 'user', 'origin_area.location', 'destination_area.location']
            ).serialized_json)
          }
        rescue => e
          Rails.logger.error "PackagesController#show serialization error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load package details' 
          }, status: :internal_server_error
        end
      end

      def create
        begin
          package = current_user.packages.build(package_params)
          package.state = 'pending_unpaid'
          
          # Generate package code using service
          begin
            code_generator = PackageCodeGenerator.new(package)
            package.code = code_generator.generate
          rescue => code_error
            Rails.logger.warn "Package code generation failed: #{code_error.message}, using fallback"
            package.code = generate_fallback_code
          end
          
          # Try to calculate cost with fallback
          begin
            if package.respond_to?(:calculate_delivery_cost)
              package.cost = package.calculate_delivery_cost
            else
              package.cost = calculate_cost(package)
            end
          rescue => cost_error
            Rails.logger.warn "Cost calculation failed: #{cost_error.message}, using fallback"
            package.cost = calculate_cost(package)
          end

          if package.save
            render json: {
              success: true,
              data: JSON.parse(PackageSerializer.new(
                package, 
                include: ['origin_area', 'destination_area', 'origin_area.location', 'destination_area.location']
              ).serialized_json),
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
            error: e.message
          }, status: :internal_server_error
        end
      end

      def update
        begin
          if @package.update(package_update_params)
            # Recalculate cost if relevant fields changed
            if package_update_params.keys.any? { |key| key.include?('area_id') || key == 'delivery_type' }
              begin
                if @package.respond_to?(:update_cost!)
                  @package.update_cost!
                elsif @package.respond_to?(:calculate_delivery_cost)
                  @package.update!(cost: @package.calculate_delivery_cost)
                else
                  @package.update!(cost: calculate_cost(@package))
                end
              rescue => cost_error
                Rails.logger.error "Failed to update cost for package #{@package.id}: #{cost_error.message}"
                # Continue without failing the entire update
              end
            end

            render json: {
              success: true,
              data: JSON.parse(PackageSerializer.new(
                @package, 
                include: ['origin_area', 'destination_area', 'origin_area.location', 'destination_area.location']
              ).serialized_json),
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
            message: 'An error occurred while updating the package' 
          }, status: :internal_server_error
        end
      end

      def destroy
        begin
          # Additional authorization check (users should only delete their own packages)
          unless @package.user == current_user
            return render json: { 
              success: false, 
              message: 'Access denied' 
            }, status: :forbidden
          end

          # Check if package can be deleted (business logic)
          unless can_be_deleted?(@package)
            return render json: { 
              success: false, 
              message: 'Package cannot be deleted in its current state. Only unpaid or pending packages can be deleted.' 
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
            message: 'An error occurred while deleting the package' 
          }, status: :internal_server_error
        end
      end

      # ADDED: Missing QR Code action
      def qr_code
        begin
          # Use your existing QrCodeGenerator service
          qr_generator = QrCodeGenerator.new(@package, qr_code_options)
          
          case params[:format]&.to_sym
          when :base64
            qr_data = qr_generator.generate_base64
            render json: {
              success: true,
              data: {
                qr_code_base64: qr_data,
                tracking_url: package_tracking_url(@package.code),
                package_code: @package.code
              },
              message: 'QR code generated successfully'
            }
          when :file
            file_path = qr_generator.generate_and_save
            render json: {
              success: true,
              data: {
                file_path: file_path.to_s,
                tracking_url: package_tracking_url(@package.code),
                package_code: @package.code
              },
              message: 'QR code file generated successfully'
            }
          else
            # Default: return PNG data as base64
            png_data = qr_generator.generate
            base64_data = "data:image/png;base64,#{Base64.encode64(png_data)}"
            
            render json: {
              success: true,
              data: {
                qr_code_base64: base64_data,
                qr_code_raw: Base64.encode64(png_data),
                tracking_url: package_tracking_url(@package.code),
                package_code: @package.code,
                package_state: @package.state,
                route_description: safe_route_description(@package)
              },
              message: 'QR code generated successfully'
            }
          end
        rescue => e
          Rails.logger.error "PackagesController#qr_code error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { 
            success: false, 
            message: 'Failed to generate QR code',
            error: e.message
          }, status: :internal_server_error
        end
      end

      def tracking_page
        begin
          render json: {
            success: true,
            data: JSON.parse(PackageSerializer.new(
              @package,
              include: ['origin_area', 'destination_area', 'origin_area.location', 'destination_area.location'],
              params: { include_qr_code: true }
            ).serialized_json),
            timeline: package_timeline(@package),
            tracking_url: package_tracking_url(@package.code)
          }
        rescue => e
          Rails.logger.error "PackagesController#tracking_page error: #{e.message}"
          # Fallback without QR code
          begin
            render json: {
              success: true,
              data: JSON.parse(PackageSerializer.new(
                @package, 
                include: ['origin_area', 'destination_area', 'origin_area.location', 'destination_area.location']
              ).serialized_json),
              tracking_url: package_tracking_url(@package.code),
              timeline: package_timeline(@package),
              message: 'Package data loaded (QR code generation failed)'
            }
          rescue => fallback_error
            Rails.logger.error "PackagesController#tracking_page fallback error: #{fallback_error.message}"
            render json: { 
              success: false, 
              message: 'Failed to load tracking information' 
            }, status: :internal_server_error
          end
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
          packages = current_user.packages.includes(:origin_area, :destination_area)

          # Use search method if available, otherwise fallback to simple LIKE query
          if Package.respond_to?(:search_by_code)
            packages = packages.search_by_code(query)
          else
            packages = packages.where("code ILIKE ?", "%#{query}%")
          end

          packages = packages.limit(20)

          # Simple serialization for search results
          serialized_packages = packages.map do |package|
            {
              id: package.id.to_s,
              code: package.code,
              state: package.state,
              state_display: package.state.humanize,
              route_description: safe_route_description(package),
              created_at: package.created_at&.iso8601
            }
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
            message: 'Search failed' 
          }, status: :internal_server_error
        end
      end

      def pay
        begin
          if @package.pending_unpaid?
            @package.update!(state: 'pending')
            render json: { 
              success: true, 
              message: 'Payment processed successfully',
              data: JSON.parse(PackageSerializer.new(@package).serialized_json)
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
            message: 'Payment processing failed' 
          }, status: :internal_server_error
        end
      end

      def submit
        begin
          if @package.pending?
            @package.update!(state: 'submitted')
            render json: { 
              success: true, 
              message: 'Package submitted for delivery',
              data: JSON.parse(PackageSerializer.new(@package).serialized_json)
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
            message: 'Package submission failed' 
          }, status: :internal_server_error
        end
      end

      private

      def force_json_format
        request.format = :json
      end

      def set_package
        @package = Package.find_by!(code: params[:id])
        
        # Generate code if missing (using your PackageCodeGenerator service)
        if @package.code.blank?
          begin
            code_generator = PackageCodeGenerator.new(@package)
            generated_code = code_generator.generate
            @package.update!(code: generated_code) if generated_code.present?
          rescue => e
            Rails.logger.error "Failed to generate package code: #{e.message}"
          end
        end
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: 'Package not found' 
        }, status: :not_found
      end

      def set_package_for_authenticated_user
        @package = current_user.packages.find_by!(code: params[:id])
        
        # Generate code if missing (using your PackageCodeGenerator service)
        if @package.code.blank?
          begin
            code_generator = PackageCodeGenerator.new(@package)
            generated_code = code_generator.generate
            @package.update!(code: generated_code) if generated_code.present?
          rescue => e
            Rails.logger.error "Failed to generate package code: #{e.message}"
          end
        end
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: 'Package not found or access denied' 
        }, status: :not_found
      end

      # ADDED: QR code options for customization
      def qr_code_options
        {
          module_size: params[:module_size]&.to_i || 12,
          border_size: params[:border_size]&.to_i || 24,
          corner_radius: params[:corner_radius]&.to_i || 4,
          data_type: params[:data_type]&.to_sym || :url,
          center_logo: params[:center_logo] != 'false', # Default true
          gradient: params[:gradient] != 'false', # Default true
          logo_size: params[:logo_size]&.to_i || 40
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

      def calculate_cost(package)
        begin
          # Enhanced fallback cost calculation
          base_cost = 150 # Base cost
          
          # Add delivery type cost
          case package.delivery_type
          when 'doorstep'
            base_cost += 100
          when 'agent'
            base_cost += 0
          when 'mixed'
            base_cost += 50
          end

          # Add distance-based cost (simplified)
          if package.origin_area_id != package.destination_area_id
            base_cost += 100 # Inter-area delivery
          end

          base_cost
        rescue => e
          Rails.logger.error "Fallback cost calculation failed: #{e.message}"
          200 # Ultimate fallback
        end
      end

      # ADDED: Fallback code generation
      def generate_fallback_code
        "PKG-#{SecureRandom.hex(4).upcase}-#{Time.current.strftime('%Y%m%d')}"
      end

      def can_be_deleted?(package)
        # Business logic: Only allow deletion if package is not yet in transit or delivered
        # Users can delete unpaid packages or packages that haven't been picked up yet
        deletable_states = ['pending_unpaid', 'pending']
        deletable_states.include?(package.state)
      end

      def package_timeline(package)
        timeline = []
        
        timeline << {
          status: 'pending_unpaid',
          timestamp: package.created_at,
          description: 'Package created, awaiting payment',
          active: package.state == 'pending_unpaid'
        }

        if package.updated_at > package.created_at
          timeline << {
            status: package.state,
            timestamp: package.updated_at,
            description: status_description(package.state),
            active: true
          }
        end

        timeline
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
        if package.respond_to?(:route_description)
          package.route_description
        else
          # Fallback route description
          origin = package.origin_area&.name || 'Unknown Origin'
          destination = package.destination_area&.name || 'Unknown Destination'
          "#{origin} → #{destination}"
        end
      rescue => e
        Rails.logger.error "Route description generation failed: #{e.message}"
        "Route information unavailable"
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
          state.humanize
        end
      end
    end
  end
end