# app/controllers/api/v1/scanning_controller.rb
module Api
  module V1
    class ScanningController < ApplicationController
      before_action :authenticate_user!
      before_action :set_package_by_code, only: [:scan_action, :package_details, :available_actions, :validate_action, :package_scan_info]
      before_action :force_json_format

      # Main scanning endpoint - handles all scanning actions based on user role
      def scan_action
        begin
          action_type = params[:action_type] # 'collect', 'deliver', 'print', 'confirm_receipt'
          offline_sync = params[:offline_sync] == true
          
          Rails.logger.info "Scanning action: #{action_type} for package #{@package.code} by user #{current_user.id} (#{current_user.role})"
          
          # Use the PackageScanningService for consistent logic
          scanning_service = PackageScanningService.new(
            package: @package,
            user: current_user,
            action_type: action_type,
            metadata: {
              offline_sync: offline_sync,
              original_timestamp: params[:original_timestamp],
              device_info: params[:device_info],
              location: params[:location],
              notes: params[:notes]
            }
          )

          result = scanning_service.execute
          
          if result[:success]
            render json: {
              success: true,
              message: result[:message],
              data: {
                package: serialize_package_for_scan(@package.reload),
                action_performed: action_type,
                performed_by: {
                  id: current_user.id,
                  name: current_user.name,
                  role: current_user.role
                },
                timestamp: Time.current.iso8601,
                next_actions: get_available_actions(@package, current_user),
                print_data: result[:data][:print_data] # Include print data if applicable
              }
            }
          else
            render json: {
              success: false,
              message: result[:message],
              error_code: result[:error_code] || 'ACTION_FAILED'
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "ScanningController#scan_action error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: {
            success: false,
            message: 'An error occurred while processing the scan',
            error_code: 'SCAN_PROCESSING_ERROR',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # Get package details for scanning (read-only)
      def package_details
        begin
          render json: {
            success: true,
            data: {
              package: serialize_package_for_scan(@package),
              available_actions: get_available_actions(@package, current_user),
              user_context: {
                role: current_user.role,
                can_collect: can_perform_action?(current_user, @package, 'collect'),
                can_deliver: can_perform_action?(current_user, @package, 'deliver'),
                can_print: can_perform_action?(current_user, @package, 'print'),
                can_confirm: can_perform_action?(current_user, @package, 'confirm_receipt'),
                can_process: can_perform_action?(current_user, @package, 'process') # warehouse
              }
            }
          }
        rescue ActiveRecord::RecordNotFound
          render json: {
            success: false,
            message: 'Package not found',
            error_code: 'PACKAGE_NOT_FOUND'
          }, status: :not_found
        rescue => e
          Rails.logger.error "ScanningController#package_details error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to load package details',
            error_code: 'LOAD_ERROR'
          }, status: :internal_server_error
        end
      end

      # Bulk scanning for processing multiple packages
      def bulk_scan
        begin
          package_codes = params[:package_codes] || []
          action_type = params[:action_type]

          if package_codes.empty?
            return render json: {
              success: false,
              message: 'No package codes provided'
            }, status: :bad_request
          end

          # Use the BulkScanningService
          bulk_service = BulkScanningService.new(
            package_codes: package_codes,
            action_type: action_type,
            user: current_user,
            metadata: {
              device_info: params[:device_info],
              location: params[:location],
              bulk_operation: true
            }
          )

          result = bulk_service.execute

          if result[:success]
            render json: {
              success: true,
              message: result[:message],
              data: result[:data]
            }
          else
            render json: {
              success: false,
              message: result[:message]
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "ScanningController#bulk_scan error: #{e.message}"
          render json: {
            success: false,
            message: 'Bulk scanning failed'
          }, status: :internal_server_error
        end
      end

      # Get available actions for a package
      def available_actions
        begin
          actions = get_available_actions(@package, current_user)
          
          render json: {
            success: true,
            data: {
              package_code: @package.code,
              package_state: @package.state,
              available_actions: actions,
              user_role: current_user.role
            }
          }
        rescue => e
          Rails.logger.error "ScanningController#available_actions error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to get available actions'
          }, status: :internal_server_error
        end
      end

      # Validate if an action can be performed
      def validate_action
        begin
          action_type = params[:action_type]
          
          can_perform = can_perform_action?(current_user, @package, action_type)
          valid_state = valid_state_for_action?(@package, action_type)
          
          render json: {
            success: true,
            data: {
              can_perform: can_perform,
              valid_state: valid_state,
              can_execute: can_perform && valid_state,
              current_state: @package.state,
              required_states: allowed_states_for_action(action_type),
              user_role: current_user.role,
              action_type: action_type
            }
          }
        rescue => e
          render json: {
            success: false,
            message: 'Validation failed'
          }, status: :internal_server_error
        end
      end

      # Get scan statistics for the user
      def scan_statistics
        begin
          stats = calculate_user_scan_stats(current_user)
          
          render json: {
            success: true,
            data: stats
          }
        rescue => e
          Rails.logger.error "ScanningController#scan_statistics error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to get scan statistics'
          }, status: :internal_server_error
        end
      end

      # Get recent scans for the user
      def recent_scans
        begin
          scans = get_recent_scans(current_user)
          
          render json: {
            success: true,
            data: scans
          }
        rescue => e
          render json: {
            success: false,
            message: 'Failed to get recent scans'
          }, status: :internal_server_error
        end
      end

      private

      def force_json_format
        request.format = :json
      end

      def set_package_by_code
        @package = Package.find_by!(code: params[:package_code])
      rescue ActiveRecord::RecordNotFound
        render json: {
          success: false,
          message: 'Package not found',
          error_code: 'PACKAGE_NOT_FOUND'
        }, status: :not_found
      end

      # Enhanced role-based permission checking
      def can_perform_action?(user, package, action_type)
        case action_type
        when 'print'
          # Agents and warehouse staff can print packages in their areas
          (user.role == 'agent' && user_has_access_to_package_area?(user, package)) ||
          (user.role == 'warehouse' && user_has_warehouse_access?(user, package)) ||
          user.role == 'admin'
          
        when 'collect'
          # Riders can collect packages from agents in origin area
          # Warehouse staff can collect packages for sorting
          (user.role == 'rider' && user_operates_in_area?(user, package.origin_area_id)) ||
          (user.role == 'warehouse' && user_has_warehouse_access?(user, package)) ||
          user.role == 'admin'
          
        when 'deliver'
          # Riders can deliver packages in destination area
          (user.role == 'rider' && user_operates_in_area?(user, package.destination_area_id)) ||
          user.role == 'admin'
          
        when 'confirm_receipt'
          # Package owner (client) can confirm receipt
          package.user_id == user.id || user.role == 'admin'
          
        when 'process'
          # Warehouse staff can process packages
          user.role == 'warehouse' || user.role == 'admin'
          
        else
          user.role == 'admin' # Admins can perform any action
        end
      end

      def valid_state_for_action?(package, action_type)
        case action_type
        when 'print'
          ['pending', 'submitted', 'in_transit', 'delivered'].include?(package.state)
        when 'collect'
          package.state == 'submitted'
        when 'deliver'
          package.state == 'in_transit'
        when 'confirm_receipt'
          package.state == 'delivered'
        when 'process'
          ['submitted', 'in_transit'].include?(package.state)
        else
          false
        end
      end

      def allowed_states_for_action(action_type)
        case action_type
        when 'print' then ['pending', 'submitted', 'in_transit', 'delivered']
        when 'collect' then ['submitted']
        when 'deliver' then ['in_transit']
        when 'confirm_receipt' then ['delivered']
        when 'process' then ['submitted', 'in_transit']
        else []
        end
      end

      def user_has_access_to_package_area?(user, package)
        return false unless user.respond_to?(:agents)
        
        user_area_ids = user.agents.pluck(:area_id)
        user_area_ids.include?(package.origin_area_id) || 
        user_area_ids.include?(package.destination_area_id)
      end

      def user_operates_in_area?(user, area_id)
        return false unless user.respond_to?(:riders)
        
        user.riders.where(area_id: area_id).exists?
      end

      def user_has_warehouse_access?(user, package)
        return false unless user.role == 'warehouse'
        return false unless user.respond_to?(:warehouse_staff)
        
        # Assume warehouse staff can access packages in their assigned locations
        user_location_ids = user.warehouse_staff.pluck(:location_id)
        package_location_ids = [
          package.origin_area&.location_id,
          package.destination_area&.location_id
        ].compact
        
        (user_location_ids & package_location_ids).any?
      end

      def get_available_actions(package, user)
        actions = []
        
        ['print', 'collect', 'deliver', 'confirm_receipt', 'process'].each do |action|
          if can_perform_action?(user, package, action) && valid_state_for_action?(package, action)
            actions << {
              action: action,
              label: action_label(action),
              description: action_description(action)
            }
          end
        end
        
        actions
      end

      def action_label(action_type)
        case action_type
        when 'print' then 'Print Package'
        when 'collect' then 'Collect Package'
        when 'deliver' then 'Mark as Delivered'
        when 'confirm_receipt' then 'Confirm Receipt'
        when 'process' then 'Process Package'
        else action_type.humanize
        end
      end

      def action_description(action_type)
        case action_type
        when 'print' then 'Generate package label and documents'
        when 'collect' then 'Mark package as collected from agent'
        when 'deliver' then 'Mark package as delivered to destination'
        when 'confirm_receipt' then 'Confirm you received the package'
        when 'process' then 'Process package in warehouse'
        else ''
        end
      end

      def serialize_package_for_scan(package)
        {
          id: package.id.to_s,
          code: package.code,
          state: package.state,
          state_display: package.state.humanize,
          sender_name: package.sender_name,
          receiver_name: package.receiver_name,
          receiver_phone: package.receiver_phone,
          route_description: package.route_description,
          cost: package.cost,
          delivery_type: package.delivery_type,
          created_at: package.created_at.iso8601,
          origin_area: serialize_area(package.origin_area),
          destination_area: serialize_area(package.destination_area),
          origin_agent: serialize_agent(package.origin_agent),
          destination_agent: serialize_agent(package.destination_agent)
        }
      end

      def serialize_area(area)
        return nil unless area
        { id: area.id.to_s, name: area.name }
      end

      def serialize_agent(agent)
        return nil unless agent
        { id: agent.id.to_s, name: agent.name, phone: agent.phone }
      end

      def calculate_user_scan_stats(user)
        today = Date.current
        
        if defined?(PackageTrackingEvent)
          user_events = PackageTrackingEvent.where(user: user)
          
          {
            packages_scanned_today: user_events.where(created_at: today.all_day).count,
            packages_processed_today: user_events.where(
              created_at: today.all_day,
              event_type: ['collected_by_rider', 'delivered_by_rider', 'printed_by_agent', 'processed_by_warehouse']
            ).count,
            total_packages_processed: user_events.count,
            last_scan_time: user_events.maximum(:created_at)&.iso8601
          }
        else
          # Fallback for demo
          {
            packages_scanned_today: rand(5..15),
            packages_processed_today: rand(3..12),
            total_packages_processed: rand(50..200),
            last_scan_time: Time.current.iso8601
          }
        end
      end

      def get_recent_scans(user)
        if defined?(PackageTrackingEvent)
          user_events = PackageTrackingEvent.includes(:package, :user)
                                           .where(user: user)
                                           .order(created_at: :desc)
                                           .limit(10)
          
          user_events.map do |event|
            {
              id: event.id,
              package_code: event.package.code,
              action_type: event.event_type,
              timestamp: event.created_at.iso8601,
              location: event.metadata['location']
            }
          end
        else
          # Demo data
          []
        end
      end
    end
  end
end