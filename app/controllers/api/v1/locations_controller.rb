# app/controllers/api/v1/locations_controller.rb
module Api
  module V1
    class LocationsController < ApplicationController
      before_action :authenticate_user!

      def index
        locations = Location.all.order(:name)
        
        render json: {
          success: true,
          locations: LocationSerializer.serialize_collection(locations)
        }
      end

      def show
        location = Location.find(params[:id])
        render json: {
          success: true,
          location: LocationSerializer.new(location)
        }
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
            location: LocationSerializer.new(location).as_json,
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

      def location_params
        params.require(:location).permit(:name, :initials)
      end
    end
  end
end