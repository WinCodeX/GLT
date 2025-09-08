# app/controllers/api/v1/prices_controller.rb - UPDATED: Added support for fragile, home, office, and collection pricing

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

      # ADDED: Calculate pricing for all delivery types based on areas and package size
      def calculate
        begin
          origin_area_id = params[:origin_area_id]
          destination_area_id = params[:destination_area_id]
          package_size = params[:package_size] || 'medium'

          if origin_area_id.blank? || destination_area_id.blank?
            render json: {
              success: false,
              message: 'Origin area and destination area are required'
            }, status: :bad_request
            return
          end

          # Find areas
          origin_area = Area.find_by(id: origin_area_id)
          destination_area = Area.find_by(id: destination_area_id)

          unless origin_area && destination_area
            render json: {
              success: false,
              message: 'Invalid area IDs provided'
            }, status: :bad_request
            return
          end

          # Calculate pricing for all delivery types
          pricing_result = calculate_all_delivery_types(origin_area, destination_area, package_size)

          render json: {
            success: true,
            data: pricing_result,
            message: 'Pricing calculated successfully'
          }

        rescue => e
          Rails.logger.error "PricesController#calculate error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to calculate pricing',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
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
          :delivery_type,
          :package_size
        )
      end

      # ADDED: Calculate pricing for all delivery types
      def calculate_all_delivery_types(origin_area, destination_area, package_size)
        # Determine if it's intra-area or inter-area/inter-location
        is_intra_area = origin_area.id == destination_area.id
        is_intra_location = origin_area.location_id == destination_area.location_id

        # Base cost calculation
        base_cost = calculate_base_cost(origin_area, destination_area, is_intra_area, is_intra_location)
        
        # Package size multiplier
        size_multiplier = get_package_size_multiplier(package_size)

        # Calculate for each delivery type
        {
          fragile: calculate_fragile_price(base_cost, size_multiplier),
          home: calculate_home_price(base_cost, size_multiplier, is_intra_area, is_intra_location),
          office: calculate_office_price(base_cost, size_multiplier, is_intra_area, is_intra_location),
          collection: calculate_collection_price(base_cost, size_multiplier)
        }
      end

      def calculate_base_cost(origin_area, destination_area, is_intra_area, is_intra_location)
        if is_intra_area
          200 # Same area base cost
        elsif is_intra_location
          280 # Same location, different areas
        else
          # Inter-location pricing based on major routes
          calculate_inter_location_cost(origin_area.location, destination_area.location)
        end
      end

      def calculate_inter_location_cost(origin_location, destination_location)
        # Major route pricing
        major_routes = {
          ['Nairobi', 'Mombasa'] => 420,
          ['Nairobi', 'Kisumu'] => 400,
          ['Mombasa', 'Kisumu'] => 390
        }

        route_key = [origin_location.name, destination_location.name].sort
        major_routes[route_key] || (
          # Default inter-location pricing
          if origin_location.name == 'Nairobi' || destination_location.name == 'Nairobi'
            380
          else
            370
          end
        )
      end

      def get_package_size_multiplier(package_size)
        case package_size
        when 'small'
          0.8
        when 'medium'
          1.0
        when 'large'
          1.4
        else
          1.0
        end
      end

      def calculate_fragile_price(base_cost, size_multiplier)
        # Fragile items have premium pricing with special handling surcharge
        fragile_base = base_cost * 1.5 # 50% premium for fragile handling
        fragile_surcharge = 100 # Fixed surcharge for special handling
        
        ((fragile_base + fragile_surcharge) * size_multiplier).round
      end

      def calculate_home_price(base_cost, size_multiplier, is_intra_area, is_intra_location)
        # Home delivery (doorstep) - standard pricing
        home_base = if is_intra_area
          base_cost * 1.2 # 20% premium for doorstep delivery within area
        elsif is_intra_location
          base_cost * 1.1 # 10% premium for doorstep delivery within location
        else
          base_cost # Standard inter-location pricing
        end

        (home_base * size_multiplier).round
      end

      def calculate_office_price(base_cost, size_multiplier, is_intra_area, is_intra_location)
        # Office delivery (collect from office) - discounted pricing
        office_discount = 0.75 # 25% discount for office collection
        office_base = base_cost * office_discount

        (office_base * size_multiplier).round
      end

      def calculate_collection_price(base_cost, size_multiplier)
        # Collection service - premium pricing for pickup service
        collection_base = base_cost * 1.3 # 30% premium for collection service
        collection_surcharge = 50 # Fixed surcharge for collection logistics
        
        ((collection_base + collection_surcharge) * size_multiplier).round
      end
    end
  end
end