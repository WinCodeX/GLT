
# Create this controller: app/controllers/public/agents_controller.rb
module Public
  class AgentsController < WebApplicationController
    skip_before_action :authenticate_user!, only: [:area]
    
    def area
      agent = Agent.find_by(id: params[:id])
      
      if agent
        render json: {
          success: true,
          area_id: agent.area_id,
          area_name: agent.area.name,
          location_name: agent.area.location.name
        }
      else
        render json: {
          success: false,
          message: 'Agent not found'
        }, status: :not_found
      end
    rescue => e
      Rails.logger.error "Error fetching agent area: #{e.message}"
      render json: {
        success: false,
        message: 'Error fetching agent information'
      }, status: :internal_server_error
    end
  end
end