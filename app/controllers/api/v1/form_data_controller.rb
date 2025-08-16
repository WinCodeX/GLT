# app/controllers/api/v1/form_data_controller.rb
module Api
  module V1
    class FormDataController < ApplicationController
      before_action :authenticate_user!
      before_action :force_json_format

      def areas
        begin
          # Get areas accessible to the current user
          areas = if current_user.admin?
                    Area.includes(:location).order(:name)
                  else
                    current_user.accessible_areas.includes(:location).order(:name)
                  end

          serialized_areas = areas.map do |area|
            {
              id: area.id.to_s,
              name: area.name,
              location: area.location ? {
                id: area.location.id.to_s,
                name: area.location.name
              } : nil
            }
          end

          render json: {
            success: true,
            data: serialized_areas,
            count: serialized_areas.length,
            user_context: {
              role: current_user.primary_role,
              total_accessible_areas: areas.count
            }
          }
        rescue => e
          Rails.logger.error "FormDataController#areas error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load areas',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def agents
        begin
          # Get agents accessible to the current user
          agents = if current_user.admin?
                     Agent.includes(area: :location).order(:name)
                   else
                     Agent.joins(:area)
                          .where(area: { id: current_user.accessible_areas })
                          .includes(area: :location)
                          .order(:name)
                   end

          serialized_agents = agents.map do |agent|
            {
              id: agent.id.to_s,
              name: agent.name,
              phone: agent.phone,
              area: agent.area ? {
                id: agent.area.id.to_s,
                name: agent.area.name,
                location: agent.area.location ? {
                  id: agent.area.location.id.to_s,
                  name: agent.area.location.name
                } : nil
              } : nil
            }
          end

          render json: {
            success: true,
            data: serialized_agents,
            count: serialized_agents.length,
            user_context: {
              role: current_user.primary_role,
              total_accessible_agents: agents.count
            }
          }
        rescue => e
          Rails.logger.error "FormDataController#agents error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load agents',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def locations
        begin
          # Get locations accessible to the current user
          locations = if current_user.admin?
                        Location.includes(:areas).order(:name)
                      else
                        Location.joins(:areas)
                                .where(areas: { id: current_user.accessible_areas })
                                .includes(:areas)
                                .distinct
                                .order(:name)
                      end

          serialized_locations = locations.map do |location|
            {
              id: location.id.to_s,
              name: location.name,
              areas_count: location.areas.count
            }
          end

          render json: {
            success: true,
            data: serialized_locations,
            count: serialized_locations.length,
            user_context: {
              role: current_user.primary_role,
              total_accessible_locations: locations.count
            }
          }
        rescue => e
          Rails.logger.error "FormDataController#locations error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load locations',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # Combined endpoint for package creation/editing forms
      def package_form_data
        begin
          # This endpoint provides all necessary data for package forms
          areas_data = if current_user.admin?
                         Area.includes(:location).order(:name)
                       else
                         current_user.accessible_areas.includes(:location).order(:name)
                       end

          agents_data = if current_user.admin?
                          Agent.includes(area: :location).order(:name)
                        else
                          Agent.joins(:area)
                               .where(area: { id: current_user.accessible_areas })
                               .includes(area: :location)
                               .order(:name)
                        end

          locations_data = if current_user.admin?
                             Location.includes(:areas).order(:name)
                           else
                             Location.joins(:areas)
                                     .where(areas: { id: current_user.accessible_areas })
                                     .includes(:areas)
                                     .distinct
                                     .order(:name)
                           end

          serialized_areas = areas_data.map do |area|
            {
              id: area.id.to_s,
              name: area.name,
              location_id: area.location_id.to_s,
              location: area.location ? {
                id: area.location.id.to_s,
                name: area.location.name
              } : nil
            }
          end

          serialized_agents = agents_data.map do |agent|
            {
              id: agent.id.to_s,
              name: agent.name,
              phone: agent.phone,
              area_id: agent.area_id.to_s,
              area: agent.area ? {
                id: agent.area.id.to_s,
                name: agent.area.name,
                location_id: agent.area.location_id.to_s,
                location: agent.area.location ? {
                  id: agent.area.location.id.to_s,
                  name: agent.area.location.name
                } : nil
              } : nil
            }
          end

          serialized_locations = locations_data.map do |location|
            {
              id: location.id.to_s,
              name: location.name,
              areas_count: location.areas.count
            }
          end

          render json: {
            success: true,
            data: {
              areas: serialized_areas,
              agents: serialized_agents,
              locations: serialized_locations
            },
            metadata: {
              areas_count: serialized_areas.length,
              agents_count: serialized_agents.length,
              locations_count: serialized_locations.length,
              user_role: current_user.primary_role,
              is_admin: current_user.admin?,
              accessible_areas_count: current_user.accessible_areas.count
            },
            message: 'Package form data loaded successfully'
          }
        rescue => e
          Rails.logger.error "FormDataController#package_form_data error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { 
            success: false, 
            message: 'Failed to load package form data',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # Get available package states based on user role
      def package_states
        begin
          # Define available states based on user role
          available_states = case current_user.primary_role
                           when 'admin'
                             # Admins can set any state
                             Package.states.keys
                           when 'client'
                             # Clients can only modify certain states for their packages
                             ['pending_unpaid', 'pending']
                           when 'agent', 'rider', 'warehouse'
                             # Staff can progress packages through workflow states
                             ['pending', 'submitted', 'in_transit', 'delivered', 'collected', 'rejected']
                           else
                             []
                           end

          state_options = available_states.map do |state|
            {
              value: state,
              label: state.humanize,
              description: get_state_description(state),
              color: get_state_color(state)
            }
          end

          render json: {
            success: true,
            data: state_options,
            count: state_options.length,
            user_context: {
              role: current_user.primary_role,
              can_edit_states: available_states.any?
            }
          }
        rescue => e
          Rails.logger.error "FormDataController#package_states error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load package states',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # Get delivery types available for packages
      def delivery_types
        begin
          delivery_type_options = [
            {
              value: 'fragile',
              label: 'Fragile Delivery',
              description: 'Special handling for delicate items',
              icon: 'alert-triangle',
              priority: 'high'
            },
            {
              value: 'doorstep',
              label: 'Doorstep Delivery', 
              description: 'Direct delivery to address',
              icon: 'home',
              priority: 'medium'
            },
            {
              value: 'agent',
              label: 'Agent Delivery',
              description: 'Collect from destination agent',
              icon: 'user',
              priority: 'standard'
            }
          ]

          render json: {
            success: true,
            data: delivery_type_options,
            count: delivery_type_options.length,
            message: 'Delivery types loaded successfully'
          }
        rescue => e
          Rails.logger.error "FormDataController#delivery_types error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load delivery types',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      private

      def force_json_format
        request.format = :json
      end

      def get_state_description(state)
        case state
        when 'pending_unpaid'
          'Package created, awaiting payment'
        when 'pending'
          'Payment received, preparing for pickup'
        when 'submitted'
          'Package submitted for delivery'
        when 'in_transit'
          'Package is in transit'
        when 'delivered'
          'Package delivered successfully'
        when 'collected'
          'Package collected by receiver'
        when 'rejected'
          'Package delivery rejected'
        else
          state.humanize
        end
      end

      def get_state_color(state)
        case state
        when 'pending_unpaid'
          '#FF3B30'
        when 'pending'
          '#FF9500'
        when 'submitted'
          '#667eea'
        when 'in_transit'
          '#764ba2'
        when 'delivered', 'collected'
          '#34C759'
        when 'rejected'
          '#FF3B30'
        else
          '#a0aec0'
        end
      end
    end
  end
end