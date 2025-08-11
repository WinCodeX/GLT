# app/controllers/api/v1/packages_controller.rb
module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!, except: [:public_tracking, :validate]
      before_action :set_package, only: [:show, :update, :destroy, :qr_code, :tracking_page, :pay, :submit]
      before_action :set_package_for_authenticated_user, only: [:pay, :submit, :update, :destroy]

      def index
        packages = current_user.packages
                              .includes(:origin_area, :destination_area, :origin_agent, :destination_agent)
                              .order(created_at: :desc)
        
        # Apply filters
        packages = apply_filters(packages)
        
        # Pagination
        page = params[:page]&.to_i || 1
        per_page = params[:per_page]&.to_i || 20
        per_page = [per_page, 100].min # Max 100 per page
        
        total_count = packages.count
        packages = packages.offset((page - 1) * per_page).limit(per_page)

        render json: {
          success: true,
          packages: PackageSerializer.serialize_collection(packages, {
            include_areas: true,
            include_agents: true
          }),
          pagination: {
            current_page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: (total_count / per_page.to_f).ceil,
            has_next: page * per_page < total_count,
            has_prev: page > 1
          }
        }
      end

      def show
        render json: {
          success: true,
          package: PackageSerializer.new(@package).as_json({
            include_areas: true,
            include_agents: true,
            include_user: true
          })
        }
      end

      def create
        package = current_user.packages.build(package_params)
        package.state = 'pending_unpaid'
        
        # Calculate cost using the enhanced method
        begin
          package.cost = package.calculate_delivery_cost
        rescue => e
          # Fallback to basic cost calculation if enhanced method fails
          package.cost = calculate_cost(package)
        end

        if package.save
          render json: {
            success: true,
            package: PackageSerializer.new(package).as_json({
              include_areas: true
            }),
            message: 'Package created successfully'
          }, status: :created
        else
          render json: { 
            success: false,
            errors: package.errors.full_messages 
          }, status: :unprocessable_entity
        end
      end

      def update
        if @package.update(package_update_params)
          # Recalculate cost if route changed
          if package_update_params.keys.any? { |key| key.include?('area_id') || key == 'delivery_type' }
            begin
              @package.update_cost!
            rescue => e
              # Log error but don't fail the update
              Rails.logger.error "Failed to update cost for package #{@package.id}: #{e.message}"
            end
          end

          render json: {
            success: true,
            package: PackageSerializer.new(@package).as_json({
              include_areas: true
            }),
            message: 'Package updated successfully'
          }
        else
          render json: { 
            success: false,
            errors: @package.errors.full_messages 
          }, status: :unprocessable_entity
        end
      end

      def destroy
        if @package.can_be_cancelled?
          @package.update!(state: 'rejected')
          render json: { 
            success: true, 
            message: 'Package cancelled successfully' 
          }
        else
          render json: { 
            success: false, 
            message: 'Package cannot be cancelled in current state' 
          }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/packages/:id/qr_code
      def qr_code
        style = params[:style] || 'purple_gradient'
        format = params[:format] || 'base64'

        qr_options = qr_style_options(style)

        begin
          case format
          when 'base64'
            base64_data = @package.qr_code_base64(qr_options)
            render json: { 
              success: true,
              qr_code: base64_data, 
              package_code: @package.code 
            }
          when 'png'
            png_data = @package.generate_qr_code(qr_options)
            send_data png_data, 
                      type: 'image/png', 
                      filename: "#{@package.code}_qr.png",
                      disposition: 'inline'
          when 'file'
            file_path = @package.qr_code_path(qr_options)
            send_file file_path, 
                      type: 'image/png', 
                      filename: "#{@package.code}_qr.png"
          else
            render json: { 
              success: false,
              error: 'Invalid format. Use: base64, png, or file' 
            }, status: :bad_request
          end
        rescue => e
          render json: {
            success: false,
            error: 'Failed to generate QR code',
            message: e.message
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/packages/:id/tracking_page
      def tracking_page
        begin
          render json: {
            success: true,
            package: PackageSerializer.new(@package).as_json({
              include_areas: true,
              include_qr_code: true
            }),
            tracking_url: @package.tracking_url,
            timeline: package_timeline(@package)
          }
        rescue => e
          render json: {
            success: true,
            package: PackageSerializer.new(@package).as_json({
              include_areas: true
            }),
            tracking_url: package_tracking_url(@package.code),
            timeline: package_timeline(@package),
            message: 'QR code generation failed but package data is available'
          }
        end
      end

      # GET /api/v1/packages/search
      def search
        query = params[:query]&.strip
        
        if query.blank?
          return render json: { 
            success: false, 
            message: 'Search query is required' 
          }, status: :bad_request
        end

        packages = current_user.packages
                              .includes(:origin_area, :destination_area)

        # Search by code if search_by_code method exists, otherwise use basic search
        if Package.respond_to?(:search_by_code)
          packages = packages.search_by_code(query)
        else
          packages = packages.where("code ILIKE ?", "%#{query}%")
        end

        packages = packages.limit(20)

        render json: {
          success: true,
          packages: PackageSerializer.serialize_collection(packages, {
            include_areas: true,
            minimal: true # Only include essential fields for search results
          }),
          query: query
        }
      end

      # GET /api/v1/packages/stats
      def stats
        packages = current_user.packages
        
        # Safe stats calculation with fallbacks
        intra_count = packages.respond_to?(:intra_area) ? packages.intra_area.count : 0
        inter_count = packages.respond_to?(:inter_area) ? packages.inter_area.count : 0
        
        stats = {
          total_packages: packages.count,
          by_state: packages.group(:state).count,
          by_delivery_type: packages.group(:delivery_type).count,
          total_cost: packages.sum(:cost),
          this_month: packages.where(created_at: Time.current.beginning_of_month..Time.current).count,
          intra_area: intra_count,
          inter_area: inter_count
        }

        render json: { success: true, stats: stats }
      end

      # POST /api/v1/packages/:id/pay
      def pay
        if @package.pending_unpaid?
          @package.update!(state: 'pending')
          render json: { 
            success: true, 
            message: 'Payment processed successfully',
            package: PackageSerializer.new(@package).as_json
          }
        else
          render json: { 
            success: false, 
            message: 'Package is not pending payment' 
          }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/packages/:id/submit
      def submit
        if @package.pending? && @package.paid?
          @package.update!(state: 'submitted')
          render json: { 
            success: true, 
            message: 'Package submitted for delivery',
            package: PackageSerializer.new(@package).as_json
          }
        else
          render json: { 
            success: false, 
            message: 'Package must be paid and pending to submit' 
          }, status: :unprocessable_entity
        end
      end

      # Public tracking endpoint (no authentication required)
      # GET /api/v1/track/:code
      def public_tracking
        package = Package.find_by(code: params[:code])
        
        unless package
          return render json: {
            success: false,
            message: "Package with tracking code '#{params[:code]}' not found"
          }, status: :not_found
        end

        # Only show limited information for public tracking
        begin
          render json: {
            success: true,
            package: public_package_data(package),
            timeline: public_package_timeline(package),
            qr_code: package.qr_code_base64
          }
        rescue => e
          # Fallback without QR code if generation fails
          render json: {
            success: true,
            package: public_package_data(package),
            timeline: public_package_timeline(package)
          }
        end
      end

      # Validate package by code (public endpoint for tracking)
      def validate
        package = Package.find_by_code_or_id(params[:id])
        
        if package
          render json: {
            success: true,
            package: PackageSerializer.new(package).as_json({
              include_areas: true,
              minimal: true
            }),
            valid: true
          }
        else
          render json: {
            success: true,
            package: nil,
            valid: false,
            message: "Package with code '#{params[:id]}' not found"
          }
        end
      end

      private

      def set_package
        @package = if Package.respond_to?(:find_by_code_or_id)
                     Package.find_by_code_or_id(params[:id])
                   else
                     Package.find_by(code: params[:id]) || Package.find_by(id: params[:id])
                   end
        
        unless @package
          render json: { 
            success: false, 
            message: "Package with identifier '#{params[:id]}' not found" 
          }, status: :not_found
        end
      end

      def set_package_for_authenticated_user
        # Ensure the package belongs to the current user for sensitive operations
        unless @package&.user == current_user
          render json: { 
            success: false, 
            message: 'Package not found or access denied' 
          }, status: :not_found
        end
      end

      def package_params
        params.require(:package).permit(
          :sender_name, :sender_phone, :receiver_name, :receiver_phone,
          :origin_area_id, :destination_area_id,
          :origin_agent_id, :destination_agent_id,
          :delivery_type
        )
      end

      def package_update_params
        params.require(:package).permit(
          :sender_name, :sender_phone, :receiver_name, :receiver_phone,
          :origin_area_id, :destination_area_id,
          :origin_agent_id, :destination_agent_id,
          :delivery_type, :state
        )
      end

      def apply_filters(packages)
        # Filter by state
        packages = packages.where(state: params[:state]) if params[:state].present?
        
        # Filter by delivery type
        packages = packages.where(delivery_type: params[:delivery_type]) if params[:delivery_type].present?
        
        # Filter by origin area
        packages = packages.where(origin_area_id: params[:origin_area_id]) if params[:origin_area_id].present?
        
        # Filter by destination area
        packages = packages.where(destination_area_id: params[:destination_area_id]) if params[:destination_area_id].present?
        
        # Filter by date range
        if params[:start_date].present?
          begin
            packages = packages.where('created_at >= ?', Date.parse(params[:start_date]))
          rescue ArgumentError
            # Invalid date format, ignore filter
          end
        end
        
        if params[:end_date].present?
          begin
            packages = packages.where('created_at <= ?', Date.parse(params[:end_date]).end_of_day)
          rescue ArgumentError
            # Invalid date format, ignore filter
          end
        end
        
        # Filter by intra/inter area
        case params[:shipment_type]
        when 'intra'
          packages = packages.where('origin_area_id = destination_area_id')
        when 'inter'
          packages = packages.where('origin_area_id != destination_area_id')
        end
        
        packages
      end

      def qr_style_options(style)
        case style
        when 'purple_gradient'
          {
            gradient: true,
            center_logo: true,
            corner_radius: 4
          }
        when 'blue'
          {
            gradient: false,
            center_logo: true,
            corner_radius: 3
          }
        when 'minimal'
          {
            gradient: false,
            center_logo: false,
            corner_radius: 2
          }
        when 'green'
          {
            gradient: false,
            center_logo: true,
            corner_radius: 3
          }
        else
          {} # Use defaults
        end
      end

      # Public package data - limited fields for security
      def public_package_data(package)
        {
          code: package.code,
          state: package.state,
          state_display: package.state.humanize,
          route_description: package.route_description,
          created_at: package.created_at,
          updated_at: package.updated_at,
          is_trackable: package.trackable?,
          delivery_type: package.delivery_type
        }
      end

      def package_timeline(package)
        timeline = []
        
        timeline << {
          status: 'created',
          timestamp: package.created_at,
          description: 'Package created',
          active: true
        }
        
        if package.respond_to?(:paid?) && package.paid?
          timeline << {
            status: 'paid',
            timestamp: package.updated_at,
            description: 'Payment received',
            active: true
          }
        end
        
        if package.submitted?
          timeline << {
            status: 'submitted',
            timestamp: package.updated_at,
            description: 'Submitted for delivery',
            active: true
          }
        end
        
        if package.in_transit?
          timeline << {
            status: 'in_transit',
            timestamp: package.updated_at,
            description: 'Package in transit',
            active: true
          }
        end
        
        if package.delivered? || package.collected?
          timeline << {
            status: 'delivered',
            timestamp: package.updated_at,
            description: package.delivered? ? 'Package delivered' : 'Package collected',
            active: true
          }
        end
        
        timeline
      end

      # Simplified timeline for public tracking (no sensitive information)
      def public_package_timeline(package)
        timeline = []
        
        timeline << {
          status: 'created',
          timestamp: package.created_at,
          description: 'Package created',
          completed: true
        }
        
        if package.respond_to?(:paid?) && package.paid?
          timeline << {
            status: 'paid',
            timestamp: package.updated_at,
            description: 'Payment confirmed',
            completed: true
          }
        end
        
        if package.submitted?
          timeline << {
            status: 'submitted',
            timestamp: package.updated_at,
            description: 'Package accepted for delivery',
            completed: true
          }
        end
        
        if package.in_transit?
          timeline << {
            status: 'in_transit',
            timestamp: package.updated_at,
            description: 'Package is in transit',
            completed: true,
            current: true
          }
        end
        
        if package.delivered? || package.collected?
          timeline << {
            status: 'delivered',
            timestamp: package.updated_at,
            description: package.delivered? ? 'Package delivered' : 'Package collected by recipient',
            completed: true
          }
        end
        
        timeline
      end

      # Fallback cost calculation method
      def calculate_cost(pkg)
        price = Price.find_by(
          origin_area_id: pkg.origin_area_id,
          destination_area_id: pkg.destination_area_id,
          origin_agent_id: pkg.origin_agent_id,
          destination_agent_id: pkg.destination_agent_id,
          delivery_type: pkg.delivery_type
        )
        price&.cost || 0
      end

      # Helper to generate tracking URL
      def package_tracking_url(code)
        "#{request.base_url}/api/v1/track/#{code}"
      end
    end
  end
end