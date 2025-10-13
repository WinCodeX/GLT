# app/controllers/api/v1/packages_controller.rb - Enhanced with notification system, resubmission logic, and business support
module Api
  module V1
    class PackagesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_package, only: [:show, :update, :destroy, :qr_code, :tracking_page, :pay, :submit, :resubmit, :reject, :resubmission_info]
      before_action :set_package_for_authenticated_user, only: [:pay, :submit, :update, :destroy, :qr_code, :resubmit]
      before_action :force_json_format
      
      # Skip authentication for public tracking redirect
      skip_before_action :authenticate_user!, only: [:public_tracking]
      skip_before_action :force_json_format, only: [:public_tracking]

      def index
        begin
          # UPDATED: Include business-related packages for staff members
          packages = get_accessible_packages_for_user
          
          packages = apply_filters(packages)
          
          page = [params[:page]&.to_i || 1, 1].max
          per_page = [[params[:per_page]&.to_i || 20, 1].max, 100].min
          
          total_count = packages.count
          packages = packages.offset((page - 1) * per_page).limit(per_page)

          # Use PackageSerializer for consistent serialization
          serialized_data = PackageSerializer.new(packages, {
            params: { 
              include_qr_code: false,
              include_business: true,
              url_helper: self
            }
          }).serializable_hash

          render json: {
            success: true,
            data: serialized_data[:data]&.map { |pkg| pkg[:attributes] } || [],
            pagination: {
              current_page: page,
              per_page: per_page,
              total_count: total_count,
              total_pages: (total_count / per_page.to_f).ceil,
              has_next: page * per_page < total_count,
              has_prev: page > 1
            },
            user_context: {
              role: current_user.primary_role,
              can_create_packages: current_user.client?,
              accessible_areas_count: get_accessible_areas_count,
              accessible_locations_count: get_accessible_locations_count
            }
          }
        rescue => e
          Rails.logger.error "PackagesController#index error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { 
            success: false, 
            message: 'Failed to load packages',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def show
        begin
          unless current_user.can_access_package?(@package)
            return render json: {
              success: false,
              message: 'Access denied to this package'
            }, status: :forbidden
          end

          # Use PackageSerializer for consistent serialization
          serialized_data = PackageSerializer.new(@package, {
            params: { 
              include_qr_code: false,
              include_business: true,
              url_helper: self
            }
          }).serializable_hash

          render json: {
            success: true,
            data: serialized_data[:data][:attributes],
            user_permissions: {
              can_edit: can_edit_package?(@package),
              can_delete: can_delete_package?(@package),
              can_resubmit: (@package.user == current_user && @package.can_be_resubmitted?),
              can_reject: can_reject_package?(@package),
              available_scanning_actions: get_available_scanning_actions(@package)
            }
          }
        rescue => e
          Rails.logger.error "PackagesController#show error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { 
            success: false, 
            message: 'Failed to load package details',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def create
        unless current_user.client?
          return render json: {
            success: false,
            message: 'Only customers can create packages'
          }, status: :forbidden
        end

        begin
          package = current_user.packages.build(package_params)
          
          # UPDATED: Support staff creating packages for businesses
          if package_params[:business_id].present?
            business = Business.find_by(id: package_params[:business_id])
            
            # Check if current user has access to this business (owner or staff)
            if business && can_create_package_for_business?(business)
              package.business = business
              Rails.logger.info "Package being created for business: #{business.name} by user: #{current_user.id}"
            else
              return render json: {
                success: false,
                message: 'You do not have permission to create packages for this business'
              }, status: :forbidden
            end
          end
          
          # FIXED: Handle area assignment differently for fragile/collection types
          if ['fragile', 'collection'].include?(package.delivery_type)
            assign_default_areas_for_location_based_delivery(package)
          else
            set_area_ids_from_agents(package)
          end
          
          package.state = 'pending_unpaid'
          package.code = generate_package_code(package) if package.code.blank?
          package.cost = calculate_package_cost(package)

          if package.save
            Rails.logger.info "Package created successfully: #{package.code} for business: #{package.business&.name || 'None'} by user: #{current_user.id}"
            
            serialized_data = PackageSerializer.new(package, {
              params: { 
                include_business: true,
                url_helper: self 
              }
            }).serializable_hash
            
            render json: {
              success: true,
              data: serialized_data[:data][:attributes],
              message: 'Package created successfully'
            }, status: :created
          else
            Rails.logger.error "Package creation failed: #{package.errors.full_messages}"
            render json: { 
              success: false,
              errors: package.errors.full_messages,
              message: 'Failed to create package'
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "PackagesController#create error: #{e.message}"
          render json: { 
            success: false, 
            message: 'An error occurred while creating the package',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def update
        begin
          unless can_edit_package?(@package)
            return render json: {
              success: false,
              message: 'You cannot edit this package'
            }, status: :forbidden
          end

          filtered_params = package_update_params

          # FIXED: Handle area assignment differently for fragile/collection types
          if ['fragile', 'collection'].include?(@package.delivery_type)
            assign_default_areas_for_location_based_delivery(@package)
          else
            if filtered_params[:origin_agent_id].present? || filtered_params[:destination_agent_id].present?
              set_area_ids_from_agents(@package, filtered_params)
            end
          end

          if filtered_params[:state] && filtered_params[:state] != @package.state
            unless valid_state_transition?(@package.state, filtered_params[:state])
              return render json: {
                success: false,
                message: "Invalid state transition from #{@package.state} to #{filtered_params[:state]}"
              }, status: :unprocessable_entity
            end
          end

          if @package.update(filtered_params)
            if should_recalculate_cost?(filtered_params)
              new_cost = calculate_package_cost(@package)
              @package.update_column(:cost, new_cost) if new_cost
            end

            serialized_data = PackageSerializer.new(@package.reload, {
              params: { 
                include_business: true,
                url_helper: self 
              }
            }).serializable_hash

            render json: {
              success: true,
              data: serialized_data[:data][:attributes],
              message: 'Package updated successfully'
            }
          else
            render json: { 
              success: false,
              errors: @package.errors.full_messages,
              message: 'Failed to update package'
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "PackagesController#update error: #{e.message}"
          render json: { 
            success: false, 
            message: 'An error occurred while updating the package',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def destroy
        begin
          unless can_delete_package?(@package)
            return render json: { 
              success: false, 
              message: 'You cannot delete this package' 
            }, status: :forbidden
          end

          unless can_be_deleted?(@package)
            return render json: { 
              success: false, 
              message: 'Package cannot be deleted in its current state' 
            }, status: :unprocessable_entity
          end

          if @package.destroy
            render json: { 
              success: true, 
              message: 'Package deleted successfully' 
            }
          else
            render json: { 
              success: false, 
              message: 'Failed to delete package',
              errors: @package.errors.full_messages 
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "PackagesController#destroy error: #{e.message}"
          render json: { 
            success: false, 
            message: 'An error occurred while deleting the package',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # ===========================================
      # NEW: RESUBMISSION AND REJECTION ENDPOINTS
      # ===========================================

      # POST /api/v1/packages/:id/resubmit
      def resubmit
        begin
          unless @package.user == current_user
            return render json: {
              success: false,
              message: 'You can only resubmit your own packages'
            }, status: :forbidden
          end

          unless @package.can_be_resubmitted?
            return render json: {
              success: false,
              message: 'Package cannot be resubmitted',
              error: 'resubmission_not_allowed',
              details: {
                resubmission_count: @package.resubmission_count,
                max_resubmissions: 2,
                is_rejected: @package.rejected?,
                final_deadline_passed: @package.final_deadline_passed?
              }
            }, status: :unprocessable_entity
          end

          reason = params[:reason] || "User requested resubmission"
          
          if @package.resubmit!(reason: reason)
            serialized_data = PackageSerializer.new(@package, {
              params: { 
                include_business: true,
                url_helper: self 
              }
            }).serializable_hash

            render json: {
              success: true,
              message: 'Package resubmitted successfully',
              data: serialized_data[:data][:attributes].merge({
                resubmission_info: {
                  count: @package.resubmission_count,
                  remaining: 2 - @package.resubmission_count,
                  new_deadline: @package.expiry_deadline&.iso8601,
                  hours_until_expiry: @package.hours_until_expiry
                }
              })
            }
          else
            render json: {
              success: false,
              message: 'Failed to resubmit package',
              error: 'resubmission_failed'
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "PackagesController#resubmit error: #{e.message}"
          render json: {
            success: false,
            message: 'Resubmission failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/packages/:id/reject
      def reject
        begin
          unless can_reject_package?(@package)
            return render json: {
              success: false,
              message: 'You do not have permission to reject this package'
            }, status: :forbidden
          end

          reason = params[:reason] || "Package rejected by administrator"
          auto_rejected = params[:auto_rejected] || false

          if @package.reject_package!(reason: reason, auto_rejected: auto_rejected)
            serialized_data = PackageSerializer.new(@package, {
              params: { 
                include_business: true,
                url_helper: self 
              }
            }).serializable_hash

            render json: {
              success: true,
              message: 'Package rejected successfully',
              data: serialized_data[:data][:attributes].merge({
                rejection_info: {
                  reason: @package.rejection_reason,
                  rejected_at: @package.rejected_at&.iso8601,
                  auto_rejected: @package.auto_rejected?,
                  can_resubmit: @package.can_be_resubmitted?,
                  resubmission_count: @package.resubmission_count,
                  final_deadline: @package.final_deadline&.iso8601
                }
              })
            }
          else
            render json: {
              success: false,
              message: 'Failed to reject package',
              error: 'rejection_failed'
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "PackagesController#reject error: #{e.message}"
          render json: {
            success: false,
            message: 'Package rejection failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/packages/:id/resubmission_info
      def resubmission_info
        begin
          render json: {
            success: true,
            data: {
              package_code: @package.code,
              state: @package.state,
              can_resubmit: @package.can_be_resubmitted?,
              resubmission_count: @package.resubmission_count,
              max_resubmissions: 2,
              remaining_resubmissions: [0, 2 - @package.resubmission_count].max,
              rejection_info: {
                rejected_at: @package.rejected_at&.iso8601,
                rejection_reason: @package.rejection_reason,
                auto_rejected: @package.auto_rejected?
              },
              deadlines: {
                expiry_deadline: @package.expiry_deadline&.iso8601,
                final_deadline: @package.final_deadline&.iso8601,
                hours_until_expiry: @package.hours_until_expiry,
                final_deadline_passed: @package.final_deadline_passed?
              },
              resubmission_timeline: {
                original: "7 days",
                first_resubmission: "3.5 days (7 days ÷ 2)",
                second_resubmission: "1 day",
                current_limit: @package.resubmission_deadline_text
              }
            }
          }
        rescue => e
          Rails.logger.error "PackagesController#resubmission_info error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to get resubmission info',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/packages/expired_summary
      def expired_summary
        begin
          # Get counts of expired packages by type
          pending_unpaid_expired = Package.pending_unpaid_expired.count
          pending_expired = Package.pending_expired.count
          approaching_deadline = Package.approaching_deadline.count
          rejected_for_deletion = Package.rejected_for_deletion.count

          render json: {
            success: true,
            data: {
              expired_counts: {
                pending_unpaid_expired: pending_unpaid_expired,
                pending_expired: pending_expired,
                total_expired: pending_unpaid_expired + pending_expired
              },
              warning_counts: {
                approaching_deadline: approaching_deadline
              },
              cleanup_counts: {
                rejected_for_deletion: rejected_for_deletion
              },
              next_cleanup_job: {
                scheduled: "Every hour",
                description: "Automatic package expiry management runs hourly"
              }
            }
          }
        rescue => e
          Rails.logger.error "PackagesController#expired_summary error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to get expired summary',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/packages/force_expiry_check
      def force_expiry_check
        begin
          # Only allow admins to force expiry checks
          unless current_user.has_role?(:admin) || current_user.has_role?(:super_admin)
            return render json: {
              success: false,
              message: 'Insufficient permissions'
            }, status: :forbidden
          end

          # Run expiry management immediately
          warning_count = Package.send_expiry_warnings!
          rejection_count = Package.auto_reject_expired_packages!
          deletion_count = Package.delete_expired_rejected_packages!

          render json: {
            success: true,
            message: 'Expiry check completed',
            data: {
              warnings_sent: warning_count,
              packages_rejected: rejection_count,
              packages_deleted: deletion_count
            }
          }
        rescue => e
          Rails.logger.error "PackagesController#force_expiry_check error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to run expiry check',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # ===========================================
      # EXISTING ENDPOINTS (UPDATED WITH BUSINESS SUPPORT)
      # ===========================================

      def search
        query = params[:query]&.strip
        
        if query.blank?
          return render json: { 
            success: false, 
            message: 'Search query is required' 
          }, status: :bad_request
        end

        begin
          # UPDATED: Use enhanced package access for search
          packages = get_accessible_packages_for_user
                      .includes(:origin_area, :destination_area, :origin_agent, :destination_agent, :business,
                               { origin_area: :location, destination_area: :location }, :user)
                      .where("code ILIKE ? OR business_name ILIKE ?", "%#{query}%", "%#{query}%")
                      .limit(20)

          serialized_data = PackageSerializer.new(packages, {
            params: { 
              include_business: true,
              url_helper: self 
            }
          }).serializable_hash

          render json: {
            success: true,
            data: serialized_data[:data]&.map { |pkg| pkg[:attributes] } || [],
            query: query,
            count: packages.count,
            user_role: current_user.primary_role
          }
        rescue => e
          Rails.logger.error "PackagesController#search error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Search failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def qr_code
        begin
          # Use QrCodeGenerator service directly like the old version
          qr_data = generate_qr_code_data(@package)
          
          render json: {
            success: true,
            data: {
              qr_code_base64: qr_data[:base64],
              tracking_url: qr_data[:tracking_url],
              package_code: @package.code,
              package_state: @package.state,
              route_description: safe_route_description(@package),
              business_name: @package.business_name_display
            },
            message: 'QR code generated successfully'
          }
        rescue => e
          Rails.logger.error "PackagesController#qr_code error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to generate QR code',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def tracking_page
        begin
          serialized_data = PackageSerializer.new(@package, {
            params: { 
              include_business: true,
              url_helper: self 
            }
          }).serializable_hash

          render json: {
            success: true,
            data: serialized_data[:data][:attributes],
            timeline: package_timeline(@package),
            tracking_url: tracking_url_for(@package.code)
          }
        rescue => e
          Rails.logger.error "PackagesController#tracking_page error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load tracking information',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/track/:code - Public tracking redirect
      def public_tracking
        package = Package.find_by(code: params[:code])
        
        if package
          # Redirect to public tracking page
          redirect_to public_package_tracking_path(package.code), allow_other_host: false
        else
          # Return 404 JSON if package not found
          render json: {
            success: false,
            message: 'Package not found',
            error: 'not_found'
          }, status: :not_found
        end
      rescue => e
        Rails.logger.error "Public tracking redirect error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        
        render json: {
          success: false,
          message: 'Tracking redirect failed',
          error: Rails.env.development? ? e.message : 'internal_error'
        }, status: :internal_server_error
      end

      def pay
        begin
          if @package.state == 'pending_unpaid'
            @package.update!(state: 'pending')
            
            serialized_data = PackageSerializer.new(@package, {
              params: { 
                include_business: true,
                url_helper: self 
              }
            }).serializable_hash
            
            render json: { 
              success: true, 
              message: 'Payment processed successfully',
              data: serialized_data[:data][:attributes]
            }
          else
            render json: { 
              success: false, 
              message: 'Package is not pending payment' 
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "PackagesController#pay error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Payment processing failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      def submit
        begin
          if @package.state == 'pending'
            @package.update!(state: 'submitted')
            
            serialized_data = PackageSerializer.new(@package, {
              params: { 
                include_business: true,
                url_helper: self 
              }
            }).serializable_hash
            
            render json: { 
              success: true, 
              message: 'Package submitted for delivery',
              data: serialized_data[:data][:attributes]
            }
          else
            render json: { 
              success: false, 
              message: 'Package must be pending to submit' 
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "PackagesController#submit error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Package submission failed',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      private

      def force_json_format
        request.format = :json
      end

      def set_package
        @package = Package.includes(:origin_area, :destination_area, :origin_agent, :destination_agent, :business,
                                   { origin_area: :location, destination_area: :location }, :user)
                         .find_by!(code: params[:id])
        ensure_package_has_code(@package)
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: 'Package not found' 
        }, status: :not_found
      end

      def set_package_for_authenticated_user
        # UPDATED: Use enhanced package access
        @package = get_accessible_packages_for_user
                    .includes(:origin_area, :destination_area, :origin_agent, :destination_agent, :business,
                             { origin_area: :location, destination_area: :location }, :user)
                    .find_by!(code: params[:id])
        ensure_package_has_code(@package)
      rescue ActiveRecord::RecordNotFound
        render json: { 
          success: false, 
          message: 'Package not found or access denied' 
        }, status: :not_found
      end

      # NEW: Enhanced method to get accessible packages including business-related packages
      def get_accessible_packages_for_user
        base_packages = current_user.accessible_packages
        
        # If user is part of any businesses as staff, include those business packages
        if current_user.respond_to?(:user_businesses) && current_user.user_businesses.exists?
          business_ids = current_user.user_businesses.where(role: 'staff').pluck(:business_id)
          
          if business_ids.any?
            # Include packages from businesses where user is staff
            business_packages = Package.where(business_id: business_ids)
            
            # Combine user's packages with business packages
            base_packages = base_packages.or(business_packages)
            
            Rails.logger.info "User #{current_user.id} has access to business packages from businesses: #{business_ids}"
          end
        end
        
        base_packages
      end

      # NEW: Check if user can create packages for a specific business
      def can_create_package_for_business?(business)
        return false unless business
        
        # Owner can always create packages
        return true if business.owner == current_user
        
        # Staff members can create packages for their business
        if current_user.respond_to?(:user_businesses)
          return current_user.user_businesses.exists?(business: business, role: 'staff')
        end
        
        false
      end

      def apply_filters(packages)
        packages = packages.where(state: params[:state]) if params[:state].present?
        packages = packages.where("code ILIKE ? OR business_name ILIKE ?", "%#{params[:search]}%", "%#{params[:search]}%") if params[:search].present?
        
        # NEW: Business filter
        packages = packages.where(business_id: params[:business_id]) if params[:business_id].present?
        
        case current_user.primary_role
        when 'agent'
          if params[:area_filter] == 'origin'
            packages = packages.where(origin_area_id: current_user.accessible_areas) if current_user.respond_to?(:accessible_areas)
          elsif params[:area_filter] == 'destination'
            packages = packages.where(destination_area_id: current_user.accessible_areas) if current_user.respond_to?(:accessible_areas)
          end
        when 'rider'
          if current_user.respond_to?(:accessible_areas) && current_user.accessible_areas.any?
            if params[:action_filter] == 'collection'
              packages = packages.where(origin_area_id: current_user.accessible_areas)
              packages = packages.where(state: 'submitted') if params[:state].blank?
            elsif params[:action_filter] == 'delivery'
              packages = packages.where(destination_area_id: current_user.accessible_areas)
              packages = packages.where(state: 'in_transit') if params[:state].blank?
            end
          end
        when 'warehouse'
          if current_user.respond_to?(:accessible_areas) && current_user.accessible_areas.any?
            packages = packages.where(
              "origin_area_id IN (?) OR destination_area_id IN (?)", 
              current_user.accessible_areas, current_user.accessible_areas
            )
          end
        end
        
        packages
      end

      # FIXED: Auto-assign default areas for fragile and collection deliveries
      def assign_default_areas_for_location_based_delivery(package)
        # For fragile and collection types, auto-assign default Nairobi areas
        default_location = Location.find_by(name: 'Nairobi') || Location.first
        return unless default_location
        
        default_area = default_location.areas.first
        return unless default_area
        
        if package.origin_area_id.blank?
          package.origin_area_id = default_area.id
          Rails.logger.info "Auto-assigned origin_area_id=#{package.origin_area_id} for #{package.delivery_type} delivery"
        end
        
        if package.destination_area_id.blank?
          package.destination_area_id = default_area.id
          Rails.logger.info "Auto-assigned destination_area_id=#{package.destination_area_id} for #{package.delivery_type} delivery"
        end
      end

      def set_area_ids_from_agents(package, params_override = nil)
        params_to_use = params_override || package.attributes.symbolize_keys

        if params_to_use[:origin_agent_id].present?
          begin
            origin_agent = Agent.find(params_to_use[:origin_agent_id])
            package.origin_area_id = origin_agent.area_id
            Rails.logger.info "Set origin_area_id=#{package.origin_area_id} from origin_agent_id=#{params_to_use[:origin_agent_id]}"
          rescue ActiveRecord::RecordNotFound
            Rails.logger.error "Origin agent not found: #{params_to_use[:origin_agent_id]}"
          end
        end

        if params_to_use[:destination_agent_id].present? && package.destination_area_id.blank?
          begin
            destination_agent = Agent.find(params_to_use[:destination_agent_id])
            package.destination_area_id = destination_agent.area_id
            Rails.logger.info "Set destination_area_id=#{package.destination_area_id} from destination_agent_id=#{params_to_use[:destination_agent_id]}"
          rescue ActiveRecord::RecordNotFound
            Rails.logger.error "Destination agent not found: #{params_to_use[:destination_agent_id]}"
          end
        end
      end

      def can_edit_package?(package)
        case current_user.primary_role
        when 'client'
          # UPDATED: Allow editing if user created the package OR if it's for a business they have access to
          return true if package.user == current_user && ['pending_unpaid', 'pending'].include?(package.state)
          
          # Check if user can edit business packages
          if package.business && can_create_package_for_business?(package.business)
            return ['pending_unpaid', 'pending'].include?(package.state)
          end
          
          false
        when 'admin'
          true
        when 'agent', 'rider', 'warehouse'
          true
        else
          false
        end
      end

      def can_delete_package?(package)
        case current_user.primary_role
        when 'client'
          # UPDATED: Allow deletion if user created the package OR if it's for a business they own
          return true if package.user == current_user
          
          # Only business owners can delete business packages (not staff)
          if package.business && package.business.owner == current_user
            return true
          end
          
          false
        when 'admin'
          true
        else
          false
        end
      end

      def can_reject_package?(package)
        case current_user.primary_role
        when 'admin', 'super_admin'
          true
        when 'agent', 'warehouse'
          true
        else
          false
        end
      end

      def get_available_scanning_actions(package)
        return [] unless current_user.respond_to?(:can_scan_packages?) && current_user.can_scan_packages?
        
        actions = []
        
        case current_user.primary_role
        when 'agent'
          case package.state
          when 'submitted'
            actions << { action: 'collect', label: 'Collect Package', available: true }
          when 'in_transit'
            actions << { action: 'process', label: 'Process Package', available: true }
          end
        when 'rider'
          case package.state
          when 'submitted'
            actions << { action: 'collect', label: 'Collect for Delivery', available: true }
          when 'in_transit'
            actions << { action: 'deliver', label: 'Mark Delivered', available: true }
          end
        when 'warehouse'
          if ['submitted', 'in_transit'].include?(package.state)
            actions << { action: 'process', label: 'Process Package', available: true }
          end
        when 'admin'
          actions << { action: 'print', label: 'Print Label', available: true }
          actions << { action: 'collect', label: 'Collect Package', available: true }
          actions << { action: 'deliver', label: 'Mark Delivered', available: true }
          actions << { action: 'process', label: 'Process Package', available: true }
        end
        
        actions
      end

      def valid_state_transition?(current_state, new_state)
        valid_transitions = {
          'pending_unpaid' => ['pending', 'rejected'],
          'pending' => ['submitted', 'rejected'],
          'submitted' => ['in_transit', 'rejected'],
          'in_transit' => ['delivered', 'rejected'],
          'delivered' => ['collected', 'rejected'],
          'collected' => [],
          'rejected' => ['pending']
        }

        return true if current_user.primary_role == 'admin'
        
        allowed_states = valid_transitions[current_state] || []
        allowed_states.include?(new_state)
      end

      def ensure_package_has_code(package)
        if package.code.blank?
          package.update!(code: generate_package_code(package))
        end
      rescue => e
        Rails.logger.error "Failed to ensure package code: #{e.message}"
      end

      def generate_package_code(package)
        if defined?(PackageCodeGenerator)
          begin
            code_generator = PackageCodeGenerator.new(package)
            return code_generator.generate
          rescue => e
            Rails.logger.warn "PackageCodeGenerator failed: #{e.message}"
          end
        end
        
        "PKG-#{SecureRandom.hex(4).upcase}-#{Time.current.strftime('%Y%m%d')}"
      end

      def calculate_package_cost(package)
        if package.respond_to?(:calculate_delivery_cost)
          begin
            return package.calculate_delivery_cost
          rescue => e
            Rails.logger.warn "Package cost calculation method failed: #{e.message}"
          end
        end
        
        base_cost = 150
        
        case package.delivery_type
        when 'doorstep', 'home'
          base_cost += 100
        when 'office'
          base_cost += 50
        when 'fragile'
          base_cost += 150
        when 'agent'
          base_cost += 0
        when 'mixed'
          base_cost += 50
        when 'collection'
          base_cost += 200
        end

        # FIXED: Handle cost calculation for location-based deliveries
        if ['fragile', 'collection'].include?(package.delivery_type)
          # Use flat rate for location-based deliveries since areas are auto-assigned
          return base_cost
        end

        origin_location_id = package.origin_area&.location&.id
        destination_location_id = package.destination_area&.location&.id
        
        if origin_location_id && destination_location_id
          if origin_location_id != destination_location_id
            base_cost += 200
          else
            base_cost += 50
          end
        else
          if package.origin_area_id != package.destination_area_id
            base_cost += 100
          end
        end

        base_cost
      rescue => e
        Rails.logger.error "Cost calculation failed: #{e.message}"
        200
      end

      def should_recalculate_cost?(params)
        cost_affecting_fields = ['origin_area_id', 'destination_area_id', 'delivery_type', 'package_size']
        params.keys.any? { |key| cost_affecting_fields.include?(key) }
      end

      def qr_code_options
        {
          module_size: params[:module_size]&.to_i || 12,
          border_size: params[:border_size]&.to_i || 24,
          corner_radius: params[:corner_radius]&.to_i || 4,
          data_type: params[:data_type]&.to_sym || :url,
          center_logo: params[:center_logo] != 'false',
          gradient: params[:gradient] != 'false',
          logo_size: params[:logo_size]&.to_i || 40
        }
      end

      def generate_qr_code_data(package)
        tracking_url = tracking_url_for(package.code)
        
        if defined?(QrCodeGenerator)
          begin
            qr_generator = QrCodeGenerator.new(package, qr_code_options)
            png_data = qr_generator.generate
            return {
              base64: "data:image/png;base64,#{Base64.encode64(png_data)}",
              tracking_url: tracking_url
            }
          rescue => e
            Rails.logger.warn "QrCodeGenerator failed: #{e.message}"
          end
        end
        
        {
          base64: nil,
          tracking_url: tracking_url
        }
      end

      def safe_route_description(package)
        return 'Route information unavailable' unless package

        begin
          if package.respond_to?(:route_description)
            package.route_description
          else
            # FIXED: Handle route description for location-based deliveries
            if ['fragile', 'collection'].include?(package.delivery_type)
              pickup = package.respond_to?(:pickup_location) ? package.pickup_location : 'Pickup Location'
              delivery = package.respond_to?(:delivery_location) ? package.delivery_location : 'Delivery Location'
              return "#{pickup} → #{delivery}"
            end
            
            origin_location = package.origin_area&.location&.name || 'Unknown Origin'
            destination_location = package.destination_area&.location&.name || 'Unknown Destination'
            
            if package.origin_area&.location&.id == package.destination_area&.location&.id
              origin_area = package.origin_area&.name || 'Unknown Area'
              destination_area = package.destination_area&.name || 'Unknown Area'
              "#{origin_location} (#{origin_area} → #{destination_area})"
            else
              "#{origin_location} → #{destination_location}"
            end
          end
        rescue => e
          Rails.logger.error "Route description generation failed: #{e.message}"
          origin = package.origin_area&.name || 'Unknown Origin'
          destination = package.destination_area&.name || 'Unknown Destination'
          "#{origin} → #{destination}"
        end
      end

      # UPDATED: Added business fields to permitted parameters
      def package_params
        base_params = [
          :sender_name, :sender_phone, :receiver_name, :receiver_phone,
          :delivery_type, :pickup_location, :package_description, :package_size,
          :special_instructions, :delivery_location,
          # NEW: Business fields
          :business_id, :business_name, :business_phone
        ]
        
        # Only require agent/area IDs for non-location-based deliveries
        delivery_type = params.dig(:package, :delivery_type)
        unless ['fragile', 'collection'].include?(delivery_type)
          base_params += [:origin_area_id, :destination_area_id, :origin_agent_id, :destination_agent_id]
        end
        
        optional_fields = [:sender_email, :receiver_email,
                          :origin_area_id, :destination_area_id, :origin_agent_id, :destination_agent_id]
        optional_fields.each do |field|
          base_params << field unless base_params.include?(field)
        end
        
        params.require(:package).permit(*base_params)
      end

      # UPDATED: Added business fields to update parameters
      def package_update_params
        base_params = [:sender_name, :sender_phone, :receiver_name, :receiver_phone, 
                      :delivery_type, :state, :pickup_location, :package_description,
                      :package_size, :special_instructions, :delivery_location,
                      # NEW: Business fields
                      :business_id, :business_name, :business_phone]
        
        # Only require agent/area IDs for non-location-based deliveries
        unless ['fragile', 'collection'].include?(@package.delivery_type)
          base_params += [:destination_area_id, :destination_agent_id, :origin_agent_id]
        end
        
        optional_fields = [:sender_email, :receiver_email,
                          :origin_area_id, :destination_area_id, :origin_agent_id, :destination_agent_id]
        optional_fields.each do |field|
          base_params << field unless base_params.include?(field)
        end
        
        permitted_params = []
        
        case current_user.primary_role
        when 'client'
          if ['pending_unpaid', 'pending'].include?(@package.state)
            permitted_params = [:sender_name, :sender_phone, :receiver_name, :receiver_phone, 
                               :destination_area_id, :destination_agent_id, :delivery_location,
                               :sender_email, :receiver_email, :pickup_location, 
                               :package_description, :package_size, :special_instructions,
                               :business_id, :business_name, :business_phone].select do |field|
              base_params.include?(field)
            end
          end
        when 'admin'
          permitted_params = base_params
        when 'agent', 'rider', 'warehouse'
          permitted_params = [:state, :destination_area_id, :destination_agent_id, :delivery_location,
                             :pickup_location, :package_description, :package_size, :special_instructions].select do |field|
            base_params.include?(field)
          end
        end
        
        filtered_params = params.require(:package).permit(*permitted_params)
        
        if filtered_params[:state].present?
          valid_states = ['pending_unpaid', 'pending', 'submitted', 'in_transit', 'delivered', 'collected', 'rejected']
          unless valid_states.include?(filtered_params[:state])
            filtered_params.delete(:state)
          end
        end
        
        filtered_params
      end

      def can_be_deleted?(package)
        deletable_states = ['pending_unpaid', 'pending']
        deletable_states.include?(package.state)
      end

      def package_timeline(package)
        [
          {
            status: 'pending_unpaid',
            timestamp: package.created_at,
            description: 'Package created, awaiting payment',
            active: package.state == 'pending_unpaid'
          },
          {
            status: package.state,
            timestamp: package.updated_at,
            description: status_description(package.state),
            active: package.state != 'pending_unpaid'
          }
        ]
      rescue => e
        Rails.logger.error "Timeline generation failed: #{e.message}"
        [
          {
            status: package.state,
            timestamp: package.created_at,
            description: 'Package status available',
            active: true
          }
        ]
      end

      def tracking_url_for(code)
        "#{request.base_url}/public/track/#{code}"
      rescue => e
        Rails.logger.error "Tracking URL generation failed: #{e.message}"
        "/public/track/#{code}"
      end

      def status_description(state)
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
        when 'cancelled'
          'Package delivery cancelled'
        else
          state&.humanize || 'Unknown status'
        end
      end

      def get_accessible_areas_count
        return 0 unless current_user.respond_to?(:accessible_areas)
        current_user.accessible_areas.count
      rescue
        0
      end

      def get_accessible_locations_count
        return 0 unless current_user.respond_to?(:accessible_locations)
        current_user.accessible_locations.count
      rescue
        0
      end
    end
  end
end