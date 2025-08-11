module Api
  module V1
    class AgentsController < ApplicationController
      before_action :authenticate_user!
      before_action :force_json_format

      def index
        agents = Agent.includes(area: :location).order(:name)
        render json: AgentSerializer.new(agents, include: ['area', 'area.location']).serialized_json
      end

      def show
        agent = Agent.find(params[:id])
        render json: AgentSerializer.new(agent, include: ['area', 'area.location']).serialized_json
      rescue ActiveRecord::RecordNotFound
        render json: {
          success: false,
          message: 'Agent not found'
        }, status: :not_found
      end

      def create
        agent = Agent.new(agent_params)
        if agent.save
          render json: {
            success: true,
            data: JSON.parse(AgentSerializer.new(agent, include: ['area', 'area.location']).serialized_json),
            message: 'Agent created successfully'
          }, status: :created
        else
          render json: {
            success: false,
            errors: agent.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      private

      def force_json_format
        request.format = :json
      end

      def agent_params
        params.require(:agent).permit(:name, :phone, :area_id, :user_id, :active)
      end
    end
  end
end
