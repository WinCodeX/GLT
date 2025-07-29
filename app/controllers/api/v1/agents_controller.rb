module Api
  module V1
    class AgentsController < ApplicationController
      before_action :authenticate_user!

      def index
        agents = Agent.includes(:area, :user)
        render json: agents.as_json(include: [:area, :user])
      end

      def create
        agent = Agent.new(agent_params)
        if agent.save
          render json: agent, status: :created
        else
          render json: { errors: agent.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def agent_params
        params.require(:agent).permit(:name, :phone, :area_id, :user_id)
      end
    end
  end
end