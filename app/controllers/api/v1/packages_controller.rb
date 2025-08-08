
# app/controllers/api/v1/packages_controller.rb
module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_package, only: [:show, :update, :destroy, :qr_code, :tracking_page]

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
          packages: packages.as_json(
            include: [:origin_area, :destination_area, :origin_agent, :destination_agent],
            methods: [:tracking_code, :route_description, :is_intra_area],
            include_status: true
          ),
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
          package: @package.as_json(
            include: [:origin_area, :destination_area, :origin_agent, :destination_agent, :user],
            methods: [:tracking_code, :route_description, :is_intra_area],
            include_status: true
          )
        }
      end

      def create
        package = current_user.packages.build(package_params)
        package.state = 'pending_unpaid'
        
        # Calculate cost using the enhanced method
        package.cost = package.calculate_delivery_cost

        if package.save
          render json: {
            success: true,
            package: package.as_json(
              include: [:origin_area, :destination_area],
              methods: [:tracking_code, :route_description],
              include_status: true
            ),
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
            @package.update_cost!
          end

          render json: {
            success: true,
            package: @package.as_json(
              include: [:origin_area, :destination_area],
              methods: [:tracking_code, :route_description],
              include_status: true
            ),
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
      end

      # GET /api/v1/packages/:id/tracking_page
      def tracking_page
        render json: {
          success: true,
          package: @package.as_json(
            include: [:origin_area, :destination_area],
            methods: [:tracking_code, :route_description],
            include_status: true
          ),
          qr_code: @package.qr_code_base64,
          tracking_url: @package.tracking_url,
          timeline: package_timeline(@package)
        }
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
                              .search_by_code(query)
                              .limit(20)

        render json: {
          success: true,
          packages: packages.as_json(
            include: [:origin_area, :destination_area],
            methods: [:tracking_code, :route_description],
            only: [:id, :code, :state, :created_at]
          ),
          query: query
        }
      end

      # GET /api/v1/packages/stats
      def stats
        packages = current_user.packages
        
        stats = {
          total_packages: packages.count,
          by_state: packages.group(:state).count,
          by_delivery_type: packages.group(:delivery_type).count,
          total_cost: packages.sum(:cost),
          this_month: packages.where(created_at: Time.current.beginning_of_month..Time.current).count,
          intra_area: packages.intra_area.count,
          inter_area: packages.inter_area.count
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
            package: @package.as_json(methods: [:tracking_code], include_status: true)
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
            package: @package.as_json(methods: [:tracking_code], include_status: true)
          }
        else
          render json: { 
            success: false, 
            message: 'Package must be paid and pending to submit' 
          }, status: :unprocessable_entity
        end
      end

      # Validate package by code (public endpoint for tracking)
      def validate
        package = Package.find_by_code_or_id(params[:id])
        
        if package
          render json: {
            success: true,
            package: package.as_json(
              include: [:origin_area, :destination_area],
              methods: [:tracking_code, :route_description],
              only: [:id, :code, :state, :created_at]
            ),
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
        @package = Package.find_by_code_or_id(params[:id])
        
        unless @package
          render json: { 
            success: false, 
            message: "Package with identifier '#{params[:id]}' not found" 
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
          packages = packages.where('created_at >= ?', Date.parse(params[:start_date]))
        end
        
        if params[:end_date].present?
          packages = packages.where('created_at <= ?', Date.parse(params[:end_date]).end_of_day)
        end
        
        # Filter by intra/inter area
        case params[:shipment_type]
        when 'intra'
          packages = packages.intra_area
        when 'inter'
          packages = packages.inter_area
        end
        
        packages
      end

      def qr_style_options(style)
        case style
        when 'purple_gradient'
          {
            gradient: true,
            gradient_start: ChunkyPNG::Color.rgb(138, 43, 226), # Purple
            gradient_end: ChunkyPNG::Color.rgb(30, 144, 255),   # Blue
            center_logo: true,
            corner_radius: 4
          }
        when 'blue'
          {
            foreground_color: ChunkyPNG::Color.rgb(30, 144, 255),
            gradient: false,
            center_logo: true,
            corner_radius: 3
          }
        when 'minimal'
          {
            foreground_color: ChunkyPNG::Color::BLACK,
            gradient: false,
            center_logo: false,
            corner_radius: 2
          }
        when 'green'
          {
            foreground_color: ChunkyPNG::Color.rgb(34, 197, 94),
            gradient: false,
            center_logo: true,
            corner_radius: 3
          }
        else
          {} # Use defaults
        end
      end

      def package_timeline(package)
        timeline = []
        
        timeline << {
          status: 'created',
          timestamp: package.created_at,
          description: 'Package created',
          active: true
        }
        
        if package.paid?
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
    end
  end
end