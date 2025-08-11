module Api
  module V1
    class PricesController < ApplicationController
      before_action :authenticate_user!
      before_action :force_json_format

      def index
        prices = Price.includes(:origin_area, :destination_area, :origin_agent, :destination_agent)
        render json: PriceSerializer.new(
          prices, 
          include: ['origin_area', 'destination_area', 'origin_agent', 'destination_agent', 'origin_area.location', 'destination_area.location']
        ).serialized_json
      end

      def create
        price = Price.new(price_params)
        if price.save
          render json: {
            success: true,
            data: JSON.parse(PriceSerializer.new(price).serialized_json),
            message: 'Price created successfully'
          }, status: :created
        else
          render json: { 
            success: false,
            errors: price.errors.full_messages 
          }, status: :unprocessable_entity
        end
      end

      private

      def force_json_format
        request.format = :json
      end

      def price_params
        params.require(:price).permit(
          :origin_area_id,
          :destination_area_id,
          :origin_agent_id,
          :destination_agent_id,
          :cost,
          :delivery_type
        )
      end
    end
  end
end