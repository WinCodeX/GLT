module Api
  module V1
    class LocationsController < ApplicationController
      before_action :authenticate_user!
      before_action :force_json_format

      def index
        locations = Location.all.order(:name)
        render json: LocationSerializer.new(locations).serialized_json
      end

      def show
        location = Location.find(params[:id])
        render json: LocationSerializer.new(location).serialized_json
      rescue ActiveRecord::RecordNotFound
        render json: {
          success: false,
          message: 'Location not found'
        }, status: :not_found
      end

      def create
        location = Location.new(location_params)
        if location.save
          render json: {
            success: true,
            data: JSON.parse(LocationSerializer.new(location).serialized_json),
            message: 'Location created successfully'
          }, status: :created
        else
          render json: {
            success: false,
            errors: location.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      private

      def force_json_format
        request.format = :json
      end

      def location_params
        params.require(:location).permit(:name, :initials)
      end
    end
  end
end