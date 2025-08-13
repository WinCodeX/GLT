# app/controllers/api/v1/scanning_controller.rb
module Api
  module V1
    class ScanningController < ApplicationController
      before_action :authenticate_user!
      before_action :set_package_by_code, only: [:scan_action]
      before_action :force_json_format

      # Main scanning endpoint - handles all scanning actions based on user role and context
      def scan_action
        begin
          action_type = params[:action_type] # 'collect', 'deliver', 'print', 'confirm_receipt'
          
          # Validate user permissions for this package
          unless can_perform_action?(current_user, @package, action_type)
            return render json: {
              success: false,
              message: 'You are not authorized to perform this action',
              error_code: 'UNAUTHORIZED_ACTION'
            }, status: :forbidden
          end

          # Validate package state for the action
          unless valid_state_for_action?(@package, action_type)
            return render json: {
              success: false,
              message: "Package cannot be #{action_type}ed in current state: #{@package.state}",
              error_code: 'INVALID_STATE',
              current_state: @package.state,
              allowed_states: allowed_states_for_action(action_type)
            }, status: :unprocessable_entity
          end

          # Perform the action
          result = perform_scanning_action(@package, action_type, current_user)
          
          if result[:success]
            render json: {
              success: true,
              message: result[:message],
              data: {
                package: serialize_package_detailed(@package.reload),
                action_performed: action_type,
                performed_by: {
                  id: current_user.id,
                  name: current_user.name,
                  role: current_user.role
                },
                timestamp: Time.current.iso8601,
                next_actions: get_next_available_actions(@package, current_user)
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
          package = Package.find_by!(code: params[:package_code])
          
          # Basic access check - anyone can view basic details
          render json: {
            success: true,
            data: {
              package: serialize_package_for_scan(package),
              available_actions: get_next_available_actions(package, current_user),
              user_context: {
                role: current_user.role,
                can_collect: can_perform_action?(current_user, package, 'collect'),
                can_deliver: can_perform_action?(current_user, package, 'deliver'),
                can_print: can_perform_action?(current_user, package, 'print'),
                can_confirm: can_perform_action?(current_user, package, 'confirm_receipt')
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

      # Bulk scanning for agents processing multiple packages
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

          results = []
          packages = Package.where(code: package_codes)

          packages.each do |package|
            if can_perform_action?(current_user, package, action_type) && 
               valid_state_for_action?(package, action_type)
              
              result = perform_scanning_action(package, action_type, current_user)
              results << {
                package_code: package.code,
                success: result[:success],
                message: result[:message],
                new_state: package.reload.state
              }
            else
              results << {
                package_code: package.code,
                success: false,
                message: 'Action not allowed for this package'
              }
            end
          end

          successful_count = results.count { |r| r[:success] }
          
          render json: {
            success: true,
            message: "Processed #{successful_count} of #{results.length} packages",
            data: {
              results: results,
              summary: {
                total: results.length,
                successful: successful_count,
                failed: results.length - successful_count
              }
            }
          }

        rescue => e
          Rails.logger.error "ScanningController#bulk_scan error: #{e.message}"
          render json: {
            success: false,
            message: 'Bulk scanning failed'
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

      def can_perform_action?(user, package, action_type)
        case action_type
        when 'print'
          # Agents can print packages in their areas
          user.role == 'agent' && 
          (user.agents.pluck(:area_id).include?(package.origin_area_id) ||
           user.agents.pluck(:area_id).include?(package.destination_area_id))
          
        when 'collect'
          # Riders can collect packages from agents in origin area
          user.role == 'rider' &&
          user.riders.joins(:area).where(area_id: package.origin_area_id).exists?
          
        when 'deliver'
          # Riders can deliver packages in destination area
          user.role == 'rider' &&
          user.riders.joins(:area).where(area_id: package.destination_area_id).exists?
          
        when 'confirm_receipt'
          # Package owner can confirm receipt
          package.user_id == user.id
          
        else
          false
        end
      end

      def valid_state_for_action?(package, action_type)
        case action_type
        when 'print'
          ['submitted', 'in_transit', 'delivered'].include?(package.state)
        when 'collect'
          package.state == 'submitted'
        when 'deliver'
          package.state == 'in_transit'
        when 'confirm_receipt'
          package.state == 'delivered'
        else
          false
        end
      end

      def allowed_states_for_action(action_type)
        case action_type
        when 'print' then ['submitted', 'in_transit', 'delivered']
        when 'collect' then ['submitted']
        when 'deliver' then ['in_transit']
        when 'confirm_receipt' then ['delivered']
        else []
        end
      end

      def perform_scanning_action(package, action_type, user)
        case action_type
        when 'print'
          perform_print_action(package, user)
        when 'collect'
          perform_collect_action(package, user)
        when 'deliver'
          perform_deliver_action(package, user)
        when 'confirm_receipt'
          perform_confirm_receipt_action(package, user)
        else
          { success: false, message: 'Unknown action type', error_code: 'UNKNOWN_ACTION' }
        end
      end

      def perform_print_action(package, user)
        # Create print log
        PackagePrintLog.create!(
          package: package,
          user: user,
          printed_at: Time.current,
          print_context: 'qr_scan'
        ) if defined?(PackagePrintLog)

        {
          success: true,
          message: 'Package ready for printing',
          print_data: {
            package_code: package.code,
            route: package.route_description,
            sender: package.sender_name,
            receiver: package.receiver_name,
            agent_name: user.name
          }
        }
      rescue => e
        Rails.logger.error "Print action failed: #{e.message}"
        { success: false, message: 'Print logging failed', error_code: 'PRINT_LOG_ERROR' }
      end

      def perform_collect_action(package, user)
        ActiveRecord::Base.transaction do
          package.update!(state: 'in_transit')
          
          # Create tracking event
          create_tracking_event(package, 'collected_by_rider', user, {
            collection_time: Time.current,
            rider_name: user.name
          })
          
          { success: true, message: 'Package collected successfully' }
        end
      rescue => e
        Rails.logger.error "Collect action failed: #{e.message}"
        { success: false, message: 'Failed to update package status', error_code: 'COLLECT_ERROR' }
      end

      def perform_deliver_action(package, user)
        ActiveRecord::Base.transaction do
          package.update!(state: 'delivered')
          
          # Create tracking event
          create_tracking_event(package, 'delivered_by_rider', user, {
            delivery_time: Time.current,
            rider_name: user.name,
            delivery_location: package.delivery_location
          })
          
          # Send notification to receiver
          NotificationService.new(package).notify_delivery_completed if defined?(NotificationService)
          
          { success: true, message: 'Package delivered successfully' }
        end
      rescue => e
        Rails.logger.error "Deliver action failed: #{e.message}"
        { success: false, message: 'Failed to update delivery status', error_code: 'DELIVERY_ERROR' }
      end

      def perform_confirm_receipt_action(package, user)
        ActiveRecord::Base.transaction do
          package.update!(state: 'collected')
          
          # Create tracking event
          create_tracking_event(package, 'confirmed_by_receiver', user, {
            confirmation_time: Time.current,
            receiver_name: user.name
          })
          
          { success: true, message: 'Package receipt confirmed' }
        end
      rescue => e
        Rails.logger.error "Confirm receipt action failed: #{e.message}"
        { success: false, message: 'Failed to confirm receipt', error_code: 'CONFIRM_ERROR' }
      end

      def create_tracking_event(package, event_type, user, metadata = {})
        return unless defined?(PackageTrackingEvent)
        
        PackageTrackingEvent.create!(
          package: package,
          event_type: event_type,
          user: user,
          metadata: metadata,
          created_at: Time.current
        )
      rescue => e
        Rails.logger.error "Failed to create tracking event: #{e.message}"
      end

      def get_next_available_actions(package, user)
        actions = []
        
        ['print', 'collect', 'deliver', 'confirm_receipt'].each do |action|
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
        else action_type.humanize
        end
      end

      def action_description(action_type)
        case action_type
        when 'print' then 'Generate package label and documents'
        when 'collect' then 'Mark package as collected from agent'
        when 'deliver' then 'Mark package as delivered to destination'
        when 'confirm_receipt' then 'Confirm you received the package'
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
          created_at: package.created_at.iso8601
        }
      end

      def serialize_package_detailed(package)
        # Reuse the existing method from PackagesController
        data = serialize_package_for_scan(package)
        
        data.merge!(
          origin_area: serialize_area(package.origin_area),
          destination_area: serialize_area(package.destination_area),
          origin_agent: serialize_agent(package.origin_agent),
          destination_agent: serialize_agent(package.destination_agent)
        )
      end

      def serialize_area(area)
        return nil unless area
        { id: area.id.to_s, name: area.name }
      end

      def serialize_agent(agent)
        return nil unless agent
        { id: agent.id.to_s, name: agent.name, phone: agent.phone }
      end
    end
  end
end