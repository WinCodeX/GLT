# app/controllers/public/agents_controller.rb
module Public
  class AgentsController < WebApplicationController
    skip_before_action :authenticate_user!, only: [:area]
    skip_before_action :verify_authenticity_token, only: [:area]
    
    # GET /public/agents/:id/area
    # Returns the area_id for a given agent (required for automatic pricing)
    def area
      begin
        agent = Agent.find(params[:id])
        
        render json: {
          success: true,
          agent_id: agent.id,
          area_id: agent.area_id,
          agent_name: agent.name,
          area_name: agent.area&.name,
          location_name: agent.area&.location&.name
        }
      rescue ActiveRecord::RecordNotFound
        render json: {
          success: false,
          error: 'Agent not found',
          message: "Agent with ID #{params[:id]} does not exist"
        }, status: :not_found
      rescue => e
        Rails.logger.error "Error fetching agent area: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        
        render json: {
          success: false,
          error: 'Internal server error',
          message: Rails.env.development? ? e.message : 'Failed to fetch agent information'
        }, status: :internal_server_error
      end
    end
  end
end