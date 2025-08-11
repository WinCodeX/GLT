# app/controllers/api/v1/agents_controller.rb
module Api
  module V1
    class AgentsController < ApplicationController
      before_action :authenticate_user!

      def index
        agents = Agent.includes(area: :location).order(:name)
        
        render json: {
          success: true,
          agents: AgentSerializer.serialize_collection(agents)
        }
      end

      def show
        agent = Agent.find(params[:id])
        render json: {
          success: true,
          agent: AgentSerializer.new(agent).as_json
        }
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
            agent: AgentSerializer.new(agent).as_json,
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

      def agent_params
        params.require(:agent).permit(:name, :phone, :area_id, :user_id, :active)
      end
    end
  end
end