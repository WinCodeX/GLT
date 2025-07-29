module Api
  module V1
    class PricesController < ApplicationController
      before_action :authenticate_user!

      def index
        prices = Price.includes(:origin_area, :destination_area, :origin_agent, :destination_agent)
        render json: prices.as_json(include: [:origin_area, :destination_area, :origin_agent, :destination_agent])
      end

      def create
        price = Price.new(price_params)
        if price.save
          render json: price, status: :created
        else
          render json: { errors: price.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

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