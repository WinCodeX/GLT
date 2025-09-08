# app/controllers/api/v1/prices_controller.rb - FIXED: Resolved 404 issues and parameter handling

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

      # FIXED: Calculate pricing - handles both GET and POST requests
      def calculate
        # Handle both GET params and POST body
        origin_area_id = params[:origin_area_id] || request_params[:origin_area_id]
        destination_area_id = params[:destination_area_id] || request_params[:destination_area_id]
        delivery_type = params[:delivery_type] || request_params[:delivery_type] || 'home'
        package_size = params[:package_size] || request_params[:package_size] || 'medium'

        # Validate required parameters
        if origin_area_id.blank? || destination_area_id.blank?
          render json: {
            success: false,
            message: 'Origin area and destination area are required',
            received_params: {
              origin_area_id: origin_area_id,
              destination_area_id: destination_area_id,
              delivery_type: delivery_type,
              package_size: package_size
            }
          }, status: :bad_request
          return
        end

        begin
          # Find areas with better error handling
          origin_area = find_area(origin_area_id)
          destination_area = find_area(destination_area_id)

          # Calculate pricing based on request type
          if params[:all_types] == 'true' || request_params[:all_types] == 'true'
            # Calculate for all delivery types
            pricing_result = calculate_all_delivery_types(origin_area, destination_area, package_size)
            
            render json: {
              success: true,
              data: pricing_result,
              route_info: {
                origin_area: origin_area.name,
                destination_area: destination_area.name,
                route_type: determine_route_type(origin_area, destination_area)
              },
              message: 'Pricing calculated for all delivery types'
            }
          else
            # Calculate for specific delivery type
            cost = calculate_single_delivery_type(origin_area, destination_area, delivery_type, package_size)
            
            render json: {
              success: true,
              cost: cost,
              delivery_type: delivery_type,
              package_size: package_size,
              route_type: determine_route_type(origin_area, destination_area),
              origin_area: origin_area.name,
              destination_area: destination_area.name,
              message: 'Pricing calculated successfully'
            }
          end

        rescue ActiveRecord::RecordNotFound => e
          render json: {
            success: false,
            message: 'Area not found',
            error: e.message
          }, status: :not_found
        rescue => e
          Rails.logger.error "PricesController#calculate error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          render json: {
            success: false,
            message: 'Failed to calculate pricing',
            error: Rails.env.development? ? e.message : 'Internal server error'
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

      # FIXED: Better parameter handling for both GET and POST
      def request_params
        if request.post? && request.content_type&.include?('application/json')
          JSON.parse(request.body.read).with_indifferent_access rescue {}
        else
          params
        end
      end

      # FIXED: Improved area finding with better error messages
      def find_area(area_id)
        area = Area.find_by(id: area_id)
        raise ActiveRecord::RecordNotFound, "Area with ID #{area_id} not found" unless area
        area
      end

      # FIXED: Calculate pricing for a single delivery type
      def calculate_single_delivery_type(origin_area, destination_area, delivery_type, package_size)
        is_intra_area = origin_area.id == destination_area.id
        is_intra_location = origin_area.location_id == destination_area.location_id
        base_cost = calculate_base_cost(origin_area, destination_area, is_intra_area, is_intra_location)
        size_multiplier = get_package_size_multiplier(package_size)

        case delivery_type.downcase
        when 'fragile'
          calculate_fragile_price(base_cost, size_multiplier)
        when 'home', 'doorstep'
          calculate_home_price(base_cost, size_multiplier, is_intra_area, is_intra_location)
        when 'office'
          calculate_office_price(base_cost, size_multiplier, is_intra_area, is_intra_location)
        when 'collection'
          calculate_collection_price(base_cost, size_multiplier)
        when 'agent'
          calculate_office_price(base_cost, size_multiplier, is_intra_area, is_intra_location) # Agent delivery same as office
        else
          calculate_home_price(base_cost, size_multiplier, is_intra_area, is_intra_location) # Default to home delivery
        end
      end

      # Calculate pricing for all delivery types
      def calculate_all_delivery_types(origin_area, destination_area, package_size)
        is_intra_area = origin_area.id == destination_area.id
        is_intra_location = origin_area.location_id == destination_area.location_id
        base_cost = calculate_base_cost(origin_area, destination_area, is_intra_area, is_intra_location)
        size_multiplier = get_package_size_multiplier(package_size)

        {
          fragile: calculate_fragile_price(base_cost, size_multiplier),
          home: calculate_home_price(base_cost, size_multiplier, is_intra_area, is_intra_location),
          office: calculate_office_price(base_cost, size_multiplier, is_intra_area, is_intra_location),
          collection: calculate_collection_price(base_cost, size_multiplier),
          agent: calculate_office_price(base_cost, size_multiplier, is_intra_area, is_intra_location) # Agent same as office
        }
      end

      def determine_route_type(origin_area, destination_area)
        if origin_area.id == destination_area.id
          'intra_area'
        elsif origin_area.location_id == destination_area.location_id
          'intra_location'
        else
          'inter_location'
        end
      end

      def calculate_base_cost(origin_area, destination_area, is_intra_area, is_intra_location)
        if is_intra_area
          200 # Same area base cost
        elsif is_intra_location
          280 # Same location, different areas
        else
          # Inter-location pricing
          calculate_inter_location_cost(origin_area.location, destination_area.location)
        end
      end

      def calculate_inter_location_cost(origin_location, destination_location)
        # FIXED: Handle nil locations gracefully
        return 350 unless origin_location && destination_location

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
        case package_size.to_s.downcase
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
        fragile_base = base_cost * 1.5 # 50% premium for fragile handling
        fragile_surcharge = 100 # Fixed surcharge for special handling
        
        ((fragile_base + fragile_surcharge) * size_multiplier).round
      end

      def calculate_home_price(base_cost, size_multiplier, is_intra_area, is_intra_location)
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
        office_discount = 0.75 # 25% discount for office collection
        office_base = base_cost * office_discount

        (office_base * size_multiplier).round
      end

      def calculate_collection_price(base_cost, size_multiplier)
        collection_base = base_cost * 1.3 # 30% premium for collection service
        collection_surcharge = 50 # Fixed surcharge for collection logistics
        
        ((collection_base + collection_surcharge) * size_multiplier).round
      end
    end
  end
end