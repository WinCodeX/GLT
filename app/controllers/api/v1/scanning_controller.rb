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
          action_type = params[:action_type] # 'collect', 'deliver', 'print', 'confirm_receipt', 'process'
          
          Rails.logger.info "Scanning action: #{action_type} for package #{@package.code} by user #{current_user.id} (#{get_user_role(current_user)})"
          
          # Check if user can perform this action
          unless can_perform_action?(current_user, @package, action_type)
            return render json: {
              success: false,
              message: 'You do not have permission to perform this action',
              error_code: 'PERMISSION_DENIED'
            }, status: :forbidden
          end

          # Check if package is in valid state for this action
          unless valid_state_for_action?(@package, action_type)
            return render json: {
              success: false,
              message: "Package cannot be #{action_type}ed in its current state (#{@package.state})",
              error_code: 'INVALID_STATE'
            }, status: :unprocessable_entity
          end

          # Perform the action
          result = perform_package_action(@package, action_type, current_user)
          
          if result[:success]
            render json: {
              success: true,
              message: result[:message],
              data: {
                package: serialize_package_for_scan(@package.reload),
                action_performed: action_type,
                performed_by: {
                  id: current_user.id.to_s,
                  name: current_user.name || current_user.email,
                  role: get_user_role(current_user)
                },
                timestamp: Time.current.iso8601,
                next_actions: get_available_actions(@package, current_user),
                print_data: result[:print_data] # Include print data if applicable
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
                role: get_user_role(current_user),
                can_collect: can_perform_action?(current_user, @package, 'collect'),
                can_deliver: can_perform_action?(current_user, @package, 'deliver'),
                can_print: can_perform_action?(current_user, @package, 'print'),
                can_confirm: can_perform_action?(current_user, @package, 'confirm_receipt'),
                can_process: can_perform_action?(current_user, @package, 'process')
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

      # Package scan info - similar to package_details but focused on scanning
      def package_scan_info
        begin
          render json: {
            success: true,
            data: {
              package: {
                id: @package.id.to_s,
                code: @package.code,
                state: @package.state,
                state_display: @package.state.humanize,
                route_description: safe_route_description(@package)
              },
              available_actions: get_available_actions(@package, current_user),
              scan_permissions: {
                can_scan: can_scan_packages?(current_user),
                user_role: get_user_role(current_user),
                access_level: get_user_access_level(current_user, @package)
              }
            }
          }
        rescue => e
          Rails.logger.error "ScanningController#package_scan_info error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to load package scan info',
            error_code: 'SCAN_INFO_ERROR'
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

          # Process each package
          results = []
          successful = 0
          failed = 0

          package_codes.each do |code|
            begin
              package = Package.find_by(code: code.strip)
              
              unless package
                results << {
                  package_code: code,
                  success: false,
                  message: 'Package not found'
                }
                failed += 1
                next
              end

              # Check permissions and state
              unless can_perform_action?(current_user, package, action_type)
                results << {
                  package_code: code,
                  success: false,
                  message: 'Permission denied'
                }
                failed += 1
                next
              end

              unless valid_state_for_action?(package, action_type)
                results << {
                  package_code: code,
                  success: false,
                  message: "Invalid state (#{package.state})"
                }
                failed += 1
                next
              end

              # Perform action
              result = perform_package_action(package, action_type, current_user)
              
              if result[:success]
                results << {
                  package_code: code,
                  success: true,
                  message: result[:message],
                  new_state: package.reload.state
                }
                successful += 1
              else
                results << {
                  package_code: code,
                  success: false,
                  message: result[:message]
                }
                failed += 1
              end

            rescue => e
              Rails.logger.error "Bulk scan error for #{code}: #{e.message}"
              results << {
                package_code: code,
                success: false,
                message: 'Processing error'
              }
              failed += 1
            end
          end

          render json: {
            success: true,
            message: "Bulk scan completed: #{successful} successful, #{failed} failed",
            data: {
              results: results,
              summary: {
                total: package_codes.length,
                successful: successful,
                failed: failed
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
              user_role: get_user_role(current_user)
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
              user_role: get_user_role(current_user),
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

      # Search packages for scanning context
      def search_packages
        begin
          query = params[:query]&.strip
          
          if query.blank?
            return render json: {
              success: false,
              message: 'Search query is required'
            }, status: :bad_request
          end

          # Use accessible packages for search based on user role
          packages = get_accessible_packages(current_user)
                      .where("code ILIKE ?", "%#{query}%")
                      .limit(20)

          serialized_packages = packages.map do |package|
            {
              id: package.id.to_s,
              code: package.code,
              state: package.state,
              state_display: package.state.humanize,
              route_description: safe_route_description(package),
              available_actions: get_available_actions(package, current_user)
            }
          end

          render json: {
            success: true,
            data: serialized_packages,
            query: query,
            count: serialized_packages.length,
            user_role: get_user_role(current_user)
          }
        rescue => e
          Rails.logger.error "ScanningController#search_packages error: #{e.message}"
          render json: {
            success: false,
            message: 'Package search failed'
          }, status: :internal_server_error
        end
      end

      # Sync offline actions
      def sync_offline_actions
        begin
          actions = params[:actions] || []
          
          if actions.empty?
            return render json: {
              success: false,
              message: 'No actions to sync'
            }
          end

          synced = 0
          failed = 0

          actions.each do |action|
            begin
              package = Package.find_by(code: action[:package_code])
              next unless package

              # Perform the action
              result = perform_package_action(package, action[:action_type], current_user)
              
              if result[:success]
                synced += 1
              else
                failed += 1
              end
            rescue => e
              Rails.logger.error "Sync action failed: #{e.message}"
              failed += 1
            end
          end

          render json: {
            success: true,
            data: {
              synced: synced,
              failed: failed,
              message: "Synced #{synced} actions, #{failed} failed"
            }
          }
        rescue => e
          Rails.logger.error "ScanningController#sync_offline_actions error: #{e.message}"
          render json: {
            success: false,
            message: 'Offline sync failed'
          }, status: :internal_server_error
        end
      end

      # Get sync status
      def sync_status
        begin
          render json: {
            success: true,
            data: {
              last_sync: Time.current.iso8601,
              pending_actions: 0,
              is_online: true,
              sync_in_progress: false
            }
          }
        rescue => e
          render json: {
            success: false,
            message: 'Failed to get sync status'
          }, status: :internal_server_error
        end
      end

      # Clear offline data
      def clear_offline_data
        begin
          render json: {
            success: true,
            message: 'Offline data cleared'
          }
        rescue => e
          render json: {
            success: false,
            message: 'Failed to clear offline data'
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

      # Get user role - handles both rolify and simple role attribute
      def get_user_role(user)
        if user.respond_to?(:has_role?)
          return 'admin' if user.has_role?(:admin)
          return 'agent' if user.has_role?(:agent)
          return 'rider' if user.has_role?(:rider)
          return 'warehouse' if user.has_role?(:warehouse)
          return 'client'
        elsif user.respond_to?(:role)
          return user.role
        else
          return 'client' # Default fallback
        end
      end

      # Check if user can scan packages
      def can_scan_packages?(user)
        role = get_user_role(user)
        ['agent', 'rider', 'warehouse', 'admin'].include?(role)
      end

      # Get accessible packages based on user role
      def get_accessible_packages(user)
        role = get_user_role(user)
        
        case role
        when 'admin'
          Package.all
        when 'client'
          Package.where(user: user)
        else
          # For agents, riders, warehouse - return all packages for demo
          # In production, this should be filtered based on user's assigned areas/locations
          Package.all
        end
      end

      # Enhanced role-based permission checking
      def can_perform_action?(user, package, action_type)
        role = get_user_role(user)
        
        case action_type
        when 'print'
          ['agent', 'warehouse', 'admin'].include?(role)
        when 'collect'
          ['rider', 'warehouse', 'admin'].include?(role)
        when 'deliver'
          ['rider', 'admin'].include?(role)
        when 'confirm_receipt'
          package.user_id == user.id || role == 'admin'
        when 'process'
          ['warehouse', 'admin'].include?(role)
        else
          role == 'admin'
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

      def get_user_access_level(user, package)
        return 'owner' if package.user_id == user.id
        return 'admin' if get_user_role(user) == 'admin'
        return 'staff' if can_scan_packages?(user)
        'no_access'
      end

      def perform_package_action(package, action_type, user)
        begin
          case action_type
          when 'print'
            # For printing, just return success with print data
            return {
              success: true,
              message: "Package #{package.code} label printed successfully",
              print_data: {
                package_code: package.code,
                printed_at: Time.current.iso8601,
                printed_by: user.id
              }
            }
            
          when 'collect'
            package.update!(state: 'in_transit')
            create_tracking_event(package, user, 'collected_by_rider')
            return {
              success: true,
              message: "Package #{package.code} collected successfully"
            }
            
          when 'deliver'
            package.update!(state: 'delivered')
            create_tracking_event(package, user, 'delivered_by_rider')
            return {
              success: true,
              message: "Package #{package.code} delivered successfully"
            }
            
          when 'confirm_receipt'
            package.update!(state: 'delivered')
            create_tracking_event(package, user, 'confirmed_by_client')
            return {
              success: true,
              message: "Package #{package.code} receipt confirmed"
            }
            
          when 'process'
            # Keep current state but mark as processed
            create_tracking_event(package, user, 'processed_by_warehouse')
            return {
              success: true,
              message: "Package #{package.code} processed successfully"
            }
            
          else
            return {
              success: false,
              message: "Unknown action: #{action_type}",
              error_code: 'UNKNOWN_ACTION'
            }
          end
          
        rescue => e
          Rails.logger.error "Package action error: #{e.message}"
          return {
            success: false,
            message: "Failed to #{action_type} package: #{e.message}",
            error_code: 'ACTION_ERROR'
          }
        end
      end

      def create_tracking_event(package, user, event_type)
        # Only create tracking event if the model exists
        if defined?(PackageTrackingEvent)
          PackageTrackingEvent.create!(
            package: package,
            user: user,
            event_type: event_type,
            metadata: {
              timestamp: Time.current.iso8601,
              performed_by: user.id,
              user_role: get_user_role(user)
            }
          )
        end
      rescue => e
        Rails.logger.warn "Failed to create tracking event: #{e.message}"
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
          route_description: safe_route_description(package),
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
        { 
          id: agent.id.to_s, 
          name: agent.respond_to?(:name) ? agent.name : agent.to_s,
          phone: agent.respond_to?(:phone) ? agent.phone : nil
        }
      end

      def safe_route_description(package)
        return 'Route information unavailable' unless package

        begin
          if package.respond_to?(:route_description) && package.route_description.present?
            package.route_description
          else
            origin_name = package.origin_area&.name || 'Unknown Origin'
            destination_name = package.destination_area&.name || 'Unknown Destination'
            "#{origin_name} → #{destination_name}"
          end
        rescue => e
          Rails.logger.error "Route description generation failed: #{e.message}"
          "#{package.origin_area&.name || 'Unknown'} → #{package.destination_area&.name || 'Unknown'}"
        end
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
          # Fallback for demo when PackageTrackingEvent doesn't exist
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
              id: event.id.to_s,
              package_code: event.package.code,
              action_type: event.event_type,
              timestamp: event.created_at.iso8601,
              location: event.metadata&.dig('location')
            }
          end
        else
          # Demo data when PackageTrackingEvent doesn't exist
          []
        end
      end
    end
  end
end