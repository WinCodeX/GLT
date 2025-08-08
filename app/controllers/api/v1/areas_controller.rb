# app/controllers/api/v1/areas_controller.rb
module Api
  module V1
    class AreasController < ApplicationController
      before_action :authenticate_user!
      before_action :set_area, only: [:show, :update, :destroy]

      def index
        areas = Area.includes(:location).order(:name)
        
        # Filter by location if specified
        areas = areas.where(location_id: params[:location_id]) if params[:location_id].present?
        
        render json: areas.as_json(
          include: :location,
          only: [:id, :name, :initials, :location_id, :created_at],
          methods: [:package_count, :active_agents_count]
        )
      end

      def show
        render json: @area.as_json(
          include: :location,
          methods: [:package_count, :active_agents_count, :route_statistics]
        )
      end

      def create
        area = Area.new(area_params)
        
        if area.save
          render json: area.as_json(
            include: :location,
            methods: [:package_count, :active_agents_count]
          ), status: :created
        else
          render json: { 
            success: false,
            errors: area.errors.full_messages 
          }, status: :unprocessable_entity
        end
      end

      def update
        if @area.update(area_params)
          render json: @area.as_json(
            include: :location,
            methods: [:package_count, :active_agents_count]
          )
        else
          render json: { 
            success: false,
            errors: @area.errors.full_messages 
          }, status: :unprocessable_entity
        end
      end

      def destroy
        if @area.can_be_deleted?
          @area.destroy
          render json: { success: true, message: 'Area deleted successfully' }
        else
          render json: { 
            success: false, 
            message: 'Cannot delete area with existing packages or agents' 
          }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/areas/:id/packages
      def packages
        packages = @area.all_packages
                        .includes(:origin_area, :destination_area, :user)
                        .order(created_at: :desc)
                        .limit(50)

        render json: packages.as_json(
          include: [:origin_area, :destination_area],
          methods: [:tracking_code, :route_description],
          only: [:id, :code, :state, :created_at, :cost]
        )
      end

      # GET /api/v1/areas/:id/routes
      def routes
        origin_routes = @area.origin_packages
                             .joins(:destination_area)
                             .group('destination_areas.name', 'destination_areas.id')
                             .count

        destination_routes = @area.destination_packages
                                  .joins(:origin_area)
                                  .group('origin_areas.name', 'origin_areas.id')
                                  .count

        render json: {
          outgoing_routes: origin_routes.map { |(name, id), count| 
            { destination: name, destination_id: id, package_count: count }
          },
          incoming_routes: destination_routes.map { |(name, id), count| 
            { origin: name, origin_id: id, package_count: count }
          }
        }
      end

      # POST /api/v1/areas/bulk_create
      def bulk_create
        areas_data = params[:areas] || []
        created_areas = []
        errors = []

        areas_data.each_with_index do |area_data, index|
          area = Area.new(area_data.permit(:name, :location_id))
          
          if area.save
            created_areas << area
          else
            errors << { index: index, errors: area.errors.full_messages }
          end
        end

        render json: {
          success: errors.empty?,
          created_count: created_areas.size,
          created_areas: created_areas.as_json(include: :location),
          errors: errors
        }
      end

      private

      def set_area
        @area = Area.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: 'Area not found' 
        }, status: :not_found
      end

      def area_params
        params.require(:area).permit(:name, :location_id, :initials)
      end
    end
  end
end