module Api
  module V1
    class AreasController < ApplicationController
      before_action :authenticate_user!

      def index
        areas = Area.includes(:location)
        render json: areas.as_json(include: :location)
      end

      def create
        area = Area.new(area_params)
        if area.save
          render json: area, status: :created
        else
          render json: { errors: area.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def area_params
        params.require(:area).permit(:name, :location_id)
      end
    end
  end
end