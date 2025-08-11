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
        
        render json: {
          success: true,
          areas: AreaSerializer.serialize_collection(areas)
        }
      end

      def show
        render json: {
          success: true,
          area: AreaSerializer.new(@area)
        }
      end

      def create
        area = Area.new(area_params)
        
        if area.save
          render json: {
            success: true,
            area: AreaSerializer.new(area),
            message: 'Area created successfully'
          }, status: :created
        else
          render json: {
            success: false,
            errors: area.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      def update
        if @area.update(area_params)
          render json: {
            success: true,
            area: AreaSerializer.new(@area),
            message: 'Area updated successfully'
          }
        else
          render json: {
            success: false,
            errors: @area.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      def destroy
        if @area.destroy
          render json: {
            success: true,
            message: 'Area deleted successfully'
          }
        else
          render json: {
            success: false,
            message: 'Failed to delete area'
          }, status: :unprocessable_entity
        end
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