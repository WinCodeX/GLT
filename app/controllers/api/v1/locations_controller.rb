# app/controllers/api/v1/locations_controller.rb
module Api
  module V1
    class LocationsController < ApplicationController
      before_action :authenticate_user!

      def index
        locations = Location.includes(:areas)
        render json: locations.as_json(include: :areas)
      end

      def create
        location = Location.new(location_params)
        if location.save
          render json: location, status: :created
        else
          render json: { errors: location.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def location_params
        params.require(:location).permit(:name)
      end
    end
  end
end