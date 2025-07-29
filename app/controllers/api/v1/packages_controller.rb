# app/controllers/api/v1/packages_controller.rb
module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!

      def index
        packages = current_user.packages.includes(:origin_area, :destination_area, :origin_agent, :destination_agent)
        render json: packages.as_json(include: [:origin_area, :destination_area, :origin_agent, :destination_agent])
      end

      def create
        package = current_user.packages.build(package_params)
        package.state = 'pending_unpaid'
        package.cost = calculate_cost(package)

        if package.save
          render json: package, status: :created
        else
          render json: { errors: package.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def package_params
        params.require(:package).permit(
          :sender_name, :sender_phone, :receiver_name, :receiver_phone,
          :origin_area_id, :destination_area_id,
          :origin_agent_id, :destination_agent_id,
          :delivery_type
        )
      end

      def calculate_cost(pkg)
        price = Price.find_by(
          origin_area_id: pkg.origin_area_id,
          destination_area_id: pkg.destination_area_id,
          origin_agent_id: pkg.origin_agent_id,
          destination_agent_id: pkg.destination_agent_id,
          delivery_type: pkg.delivery_type
        )
        price&.cost || 0
      end
    end
  end
end