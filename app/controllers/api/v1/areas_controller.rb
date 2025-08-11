module Api
  module V1
    class AreasController < ApplicationController
      before_action :authenticate_user!
      before_action :set_area, only: [:show, :update, :destroy]
      before_action :force_json_format

      def index
        areas = Area.includes(:location).order(:name)
        areas = areas.where(location_id: params[:location_id]) if params[:location_id].present?
        
        render json: AreaSerializer.new(areas, include: [:location]).serialized_json
      end

      def show
        render json: AreaSerializer.new(@area, include: [:location]).serialized_json
      end

      def create
        area = Area.new(area_params)
        
        if area.save
          render json: {
            success: true,
            data: JSON.parse(AreaSerializer.new(area, include: [:location]).serialized_json),
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
            data: JSON.parse(AreaSerializer.new(@area, include: [:location]).serialized_json),
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

      def force_json_format
        request.format = :json
      end

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