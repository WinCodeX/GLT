module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_package, only: [:show, :update, :destroy, :qr_code, :tracking_page, :pay, :submit]
      before_action :set_package_for_authenticated_user, only: [:pay, :submit, :update, :destroy]
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
      end

      def show
        render json: PackageSerializer.new(
          @package,
          include: ['origin_area', 'destination_area', 'origin_agent', 'destination_agent', 'user', 'origin_area.location', 'destination_area.location']
        ).serialized_json
      end

      def create
        package = current_user.packages.build(package_params)
        package.state = 'pending_unpaid'
        
        begin
          package.cost = package.calculate_delivery_cost
        rescue => e
          package.cost = calculate_cost(package)
        end

        if package.save
          render json: {
            success: true,
            data: JSON.parse(PackageSerializer.new(package, include: ['origin_area', 'destination_area', 'origin_area.location', 'destination_area.location']).serialized_json),
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
          if package_update_params.keys.any? { |key| key.include?('area_id') || key == 'delivery_type' }
            begin
              @package.update_cost!
            rescue => e
              Rails.logger.error "Failed to update cost for package #{@package.id}: #{e.message}"
            end
          end

          render json: {
            success: true,
            data: JSON.parse(PackageSerializer.new(@package, include: ['origin_area', 'destination_area', 'origin_area.location', 'destination_area.location']).serialized_json),
            message: 'Package updated successfully'
          }
        else
          render json: { 
            success: false,
            errors: @package.errors.full_messages 
          }, status: :unprocessable_entity
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
            timeline: package_timeline(@package)
          }
        rescue => e
          render json: {
            success: true,
            data: JSON.parse(PackageSerializer.new(@package, include: ['origin_area', 'destination_area', 'origin_area.location', 'destination_area.location']).serialized_json),
            tracking_url: package_tracking_url(@package.code),
            timeline: package_timeline(@package),
            message: 'QR code generation failed but package data is available'
          }
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

        packages = current_user.packages.includes(:origin_area, :destination_area)

        if Package.respond_to?(:search_by_code)
          packages = packages.search_by_code(query)
        else
          packages = packages.where("code ILIKE ?", "%#{query}%")
        end

        packages = packages.limit(20)

        # For search results, only include essential fields
        serialized_packages = packages.map do |package|
          {
            id: package.id.to_s,
            code: package.code,
            state: package.state,
            state_display: package.state.humanize,
            route_description: package.route_description,
            created_at: package.created_at&.iso8601
          }
        end

        render json: {
          success: true,
          data: serialized_packages,
          query: query
        }
      end

      def pay
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
      end

      def submit
        if @package.pending? && @package.paid?
          @package.update!(state: 'submitted')
          render json: { 
            success: true, 
            message: 'Package submitted for delivery',
            data: JSON.parse(PackageSerializer.new(@package).serialized_json)
          }
        else
          render json: { 
            success: false, 
            message: 'Package must be paid and pending to submit' 
          }, status: :unprocessable_entity
        end
      end

      # ... rest of the methods remain the same for now ...

      private

      def force_json_format
        request.format = :json
      end

      # ... rest of private methods remain the same ...
    end
  end
end