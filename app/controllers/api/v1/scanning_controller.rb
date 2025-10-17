# app/controllers/api/v1/scanning_controller.rb - FIXED: Area access authorization
module Api
  module V1
    class ScanningController < ApplicationController
      before_action :authenticate_user!
      before_action :force_json_format

      def package_details
        package_code = params[:package_code]&.strip
        
        if package_code.blank?
          return render json: {
            success: false,
            message: 'Package code is required'
          }, status: :bad_request
        end

        begin
          package = Package.find_by!(code: package_code)
          
          unless current_user.can_access_package?(package)
            return render json: {
              success: false,
              message: 'Access denied to this package'
            }, status: :forbidden
          end

          # Get available actions based on current state and user role
          available_actions = get_available_scanning_actions(package, current_user)
          
          render json: {
            success: true,
            data: {
              package: serialize_package_for_scanning(package),
              available_actions: available_actions,
              user_context: {
                role: current_user.primary_role,
                can_collect: can_perform_action?('collect', package, current_user),
                can_deliver: can_perform_action?('deliver', package, current_user),
                can_print: can_perform_action?('print', package, current_user),
                can_confirm: can_perform_action?('confirm_receipt', package, current_user),
                can_process: can_perform_action?('process', package, current_user),
                can_edit: can_edit_package?(package, current_user)
              }
            }
          }
        rescue ActiveRecord::RecordNotFound
          render json: {
            success: false,
            message: 'Package not found'
          }, status: :not_found
        rescue => e
          Rails.logger.error "Scanning package_details error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to get package details',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def scan_action
        package_code = params[:package_code]&.strip
        action_type = params[:action_type]&.strip
        metadata = params[:metadata] || {}

        Rails.logger.info "🚀 Starting scan_action: package=#{package_code}, action=#{action_type}, user=#{current_user.id}"

        if package_code.blank? || action_type.blank?
          Rails.logger.error "❌ Missing required parameters"
          return render json: {
            success: false,
            message: 'Package code and action type are required'
          }, status: :bad_request
        end

        begin
          package = Package.find_by!(code: package_code)
          Rails.logger.info "📦 Package found: #{package.code}, state: #{package.state}"
          
          unless current_user.can_access_package?(package)
            Rails.logger.error "❌ Access denied to package"
            return render json: {
              success: false,
              message: 'Access denied to this package'
            }, status: :forbidden
          end

          Rails.logger.info "✅ Access granted, creating scanning service"

          # Use PackageScanningService for consistent state management
          scanning_service = PackageScanningService.new(
            package: package,
            user: current_user,
            action_type: action_type,
            metadata: metadata
          )

          Rails.logger.info "🔄 Executing scanning service"
          result = scanning_service.execute

          Rails.logger.info "📊 Scanning service result: success=#{result[:success]}, message=#{result[:message]}"

          if result[:success]
            render json: {
              success: true,
              message: result[:message],
              data: {
                package_code: package.code,
                previous_state: package.state_was,
                new_state: package.reload.state,
                action_performed: action_type,
                timestamp: Time.current.iso8601,
                print_data: result[:data] && result[:data][:print_data] ? result[:data][:print_data] : nil
              }
            }
          else
            Rails.logger.error "❌ Scanning service failed: #{result[:message]}"
            render json: {
              success: false,
              message: result[:message],
              error_code: result[:error_code]
            }, status: :unprocessable_entity
          end

        rescue ActiveRecord::RecordNotFound
          Rails.logger.error "❌ Package not found: #{package_code}"
          render json: {
            success: false,
            message: 'Package not found'
          }, status: :not_found
        rescue => e
          Rails.logger.error "❌ Scanning scan_action error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: {
            success: false,
            message: 'Failed to perform scan action',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def bulk_scan
        package_codes = params[:package_codes]
        action_type = params[:action_type]&.strip
        metadata = params[:metadata] || {}

        if package_codes.blank? || action_type.blank?
          return render json: {
            success: false,
            message: 'Package codes and action type are required'
          }, status: :bad_request
        end

        begin
          results = []
          successful_count = 0
          failed_count = 0

          package_codes.each do |package_code|
            begin
              package = Package.find_by!(code: package_code.strip)
              
              next unless current_user.can_access_package?(package)

              scanning_service = PackageScanningService.new(
                package: package,
                user: current_user,
                action_type: action_type,
                metadata: metadata.merge(bulk_operation: true)
              )

              result = scanning_service.execute

              if result[:success]
                successful_count += 1
                results << {
                  package_code: package_code,
                  success: true,
                  message: result[:message],
                  new_state: package.reload.state,
                  printed: result[:data] && result[:data][:print_data].present?
                }
              else
                failed_count += 1
                results << {
                  package_code: package_code,
                  success: false,
                  message: result[:message],
                  printed: false
                }
              end

            rescue ActiveRecord::RecordNotFound
              failed_count += 1
              results << {
                package_code: package_code,
                success: false,
                message: 'Package not found',
                printed: false
              }
            rescue => e
              failed_count += 1
              results << {
                package_code: package_code,
                success: false,
                message: "Error: #{e.message}",
                printed: false
              }
            end
          end

          render json: {
            success: true,
            data: {
              results: results,
              summary: {
                total: package_codes.length,
                successful: successful_count,
                failed: failed_count,
                success_rate: ((successful_count.to_f / package_codes.length) * 100).round(2)
              }
            },
            message: "Processed #{successful_count} of #{package_codes.length} packages successfully"
          }

        rescue => e
          Rails.logger.error "Bulk scanning error: #{e.message}"
          render json: {
            success: false,
            message: 'Bulk scanning failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # Debug endpoint to test package and user states
      def debug_package
        package_code = params[:package_code]&.strip
        action_type = params[:action_type]&.strip

        if package_code.blank? || action_type.blank?
          return render json: {
            success: false,
            message: 'Package code and action type are required'
          }, status: :bad_request
        end

        begin
          package = Package.find_by!(code: package_code)
          
          debug_info = {
            package: {
              code: package.code,
              state: package.state,
              origin_area_id: package.origin_area_id,
              destination_area_id: package.destination_area_id,
              user_id: package.user_id,
              delivery_type: package.delivery_type,
              is_location_based: package.location_based_delivery?
            },
            user: {
              id: current_user.id,
              role: current_user.primary_role,
              email: current_user.email,
              has_rider_records: current_user.riders.any?,
              rider_area_ids: current_user.riders.pluck(:area_id).compact
            },
            action_type: action_type,
            validations: {
              can_access_package: current_user.can_access_package?(package),
              user_operates_in_origin: user_operates_in_area?(current_user, package.origin_area_id),
              user_operates_in_destination: user_operates_in_area?(current_user, package.destination_area_id),
              package_owner: package.user_id == current_user.id,
              accessible_areas_count: current_user.accessible_areas.count,
              has_unrestricted_access: current_user.send(:has_unrestricted_area_access?, current_user.accessible_areas)
            }
          }

          # Test the scanning service validation
          scanning_service = PackageScanningService.new(
            package: package,
            user: current_user,
            action_type: action_type,
            metadata: {}
          )

          debug_info[:service_validations] = {
            valid: scanning_service.valid?,
            errors: scanning_service.errors.full_messages,
            authorized: scanning_service.send(:authorized?),
            valid_state: scanning_service.send(:valid_state_for_action?)
          }

          render json: {
            success: true,
            debug_info: debug_info
          }

        rescue ActiveRecord::RecordNotFound
          render json: {
            success: false,
            message: 'Package not found'
          }, status: :not_found
        rescue => e
          render json: {
            success: false,
            message: e.message,
            backtrace: Rails.env.development? ? e.backtrace[0..10] : nil
          }, status: :internal_server_error
        end
      end

      private

      def force_json_format
        request.format = :json
      end

      def serialize_package_for_scanning(package)
        {
          id: package.id.to_s,
          code: package.code,
          state: package.state,
          state_display: package.state&.humanize,
          sender_name: package.sender_name,
          receiver_name: package.receiver_name,
          receiver_phone: package.receiver_phone,
          route_description: package.route_description,
          cost: package.cost,
          delivery_type: package.delivery_type,
          created_at: package.created_at&.iso8601,
          updated_at: package.updated_at&.iso8601,
          tracking_url: package_tracking_url(package.code)
        }
      end

      # Get available scanning actions based on user role and package state
      def get_available_scanning_actions(package, user)
        actions = []
        
        case user.primary_role
        when 'agent'
          if package.state == 'submitted' && user_operates_in_area?(user, package.origin_area_id)
            actions << { action: 'collect', label: 'Collect from Sender', description: 'Collect package from sender' }
          end
          
          if ['pending', 'submitted', 'in_transit', 'delivered'].include?(package.state)
            actions << { action: 'print', label: 'Print Label', description: 'Print package label or receipt' }
          end
          
        when 'rider'
          if package.state == 'submitted' && user_operates_in_area?(user, package.origin_area_id)
            actions << { action: 'collect', label: 'Collect for Delivery', description: 'Collect package for delivery' }
          end
          
          if package.state == 'in_transit' && user_operates_in_area?(user, package.destination_area_id)
            actions << { action: 'deliver', label: 'Mark as Delivered', description: 'Mark package as delivered' }
          end
          
          if package.state == 'delivered'
            actions << { action: 'print', label: 'Print Delivery Receipt', description: 'Print delivery confirmation receipt' }
          end
          
        when 'warehouse'
          if ['submitted', 'in_transit'].include?(package.state)
            actions << { action: 'collect', label: 'Receive at Warehouse', description: 'Mark package as received at warehouse' }
            actions << { action: 'process', label: 'Process Package', description: 'Process package for dispatch' }
          end
          
          if ['submitted', 'in_transit', 'delivered'].include?(package.state)
            actions << { action: 'print', label: 'Print Sorting Label', description: 'Print sorting and dispatch labels' }
          end
          
        when 'client'
          if package.state == 'delivered' && package.user_id == user.id
            actions << { action: 'confirm_receipt', label: 'Confirm Receipt', description: 'Confirm you received the package' }
          end
          
        when 'admin'
          # Admin can perform any action on any package
          actions << { action: 'collect', label: 'Collect Package', description: 'Mark package as collected' }
          actions << { action: 'deliver', label: 'Mark as Delivered', description: 'Mark package as delivered' }
          actions << { action: 'process', label: 'Process Package', description: 'Process package' }
          actions << { action: 'print', label: 'Print Label/Receipt', description: 'Print package labels and receipts' }
          
          if package.state == 'delivered'
            actions << { action: 'confirm_receipt', label: 'Confirm Receipt', description: 'Confirm package receipt' }
          end
        end
        
        actions
      end

      def can_perform_action?(action, package, user)
        available_actions = get_available_scanning_actions(package, user)
        available_actions.any? { |a| a[:action] == action }
      end

      def can_edit_package?(package, user)
        case user.primary_role
        when 'client'
          package.user == user && ['pending_unpaid', 'pending'].include?(package.state)
        when 'admin'
          true
        when 'agent', 'rider', 'warehouse'
          true # Can edit state and some fields
        else
          false
        end
      end

      # FIXED: Check if user can operate in a specific area
      # This matches the logic in User#operates_in_area?
      def user_operates_in_area?(user, area_id)
        # Admin has access to all areas
        return true if user.primary_role == 'admin'
        
        # Allow access to packages without area restrictions (location-based deliveries)
        return true if area_id.nil?
        
        # Delegate to user's operates_in_area? method if available
        if user.respond_to?(:operates_in_area?)
          user.operates_in_area?(area_id)
        elsif user.respond_to?(:accessible_areas)
          # Fallback: check accessible_areas directly
          areas = user.accessible_areas
          
          # If user has unrestricted access, grant permission
          return true if has_unrestricted_access?(user, areas)
          
          # Check if specific area is accessible
          areas.exists?(id: area_id)
        else
          # Final fallback: no restrictions defined
          true
        end
      rescue => e
        Rails.logger.error "Error checking area operation: #{e.message}"
        Rails.logger.error e.backtrace[0..5].join("\n")
        # On error, deny access for non-admins
        user.primary_role == 'admin'
      end

      # Check if user has unrestricted access to all areas
      def has_unrestricted_access?(user, areas)
        return false if areas.nil?
        
        # Check if areas relation represents all areas
        begin
          total_areas = Area.count
          return false if total_areas.zero?
          
          # Compare SQL to detect Area.all relation
          areas_sql = areas.to_sql
          all_areas_sql = Area.all.to_sql
          
          return true if areas_sql == all_areas_sql
          
          # Fallback: check count (but avoid loading all records)
          areas.limit(nil).count == total_areas
        rescue
          false
        end
      end

      def package_tracking_url(code)
        "#{request.base_url}/track/#{code}"
      rescue => e
        Rails.logger.error "Tracking URL generation failed: #{e.message}"
        "/track/#{code}"
      end
    end
  end
end