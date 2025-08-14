# app/controllers/api/v1/users_controller.rb
module Api
  module V1
    class UsersController < ApplicationController
      before_action :authenticate_user!
      before_action :ensure_admin, only: [:index, :assign_role]
      before_action :force_json_format

      # GET /api/v1/users/me
      def me
        render json: {
          success: true,
          data: current_user.as_json(include_role_details: true)
        }
      end

      # GET /api/v1/users
      def index
        users = User.includes(:roles, :avatar_attachment, :avatar_blob)
        
        serialized_users = users.map do |user|
          user.as_json(include_role_details: true, include_stats: false)
        end
        
        render json: {
          success: true,
          data: serialized_users
        }
      end

      # PATCH /api/v1/users/:id/assign_role
      def assign_role
        user = User.find(params[:id])
        role = params[:role]

        if Role.exists?(name: role)
          user.add_role(role.to_sym)
          render json: { 
            success: true,
            message: "#{role} role assigned to #{user.email}",
            data: user.as_json(include_role_details: true)
          }
        else
          render json: { 
            success: false,
            error: "Invalid role: #{role}" 
          }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/users/update
      def update
        if current_user.update(user_params)
          render json: {
            success: true,
            data: current_user.as_json(include_role_details: true),
            message: 'Profile updated successfully'
          }
        else
          render json: { 
            success: false,
            errors: current_user.errors.full_messages 
          }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/users/scanning_stats
      def scanning_stats
        begin
          date_range = parse_date_range
          stats = current_user.scanning_stats(date_range)
          
          render json: {
            success: true,
            data: stats,
            period: {
              start: date_range.begin,
              end: date_range.end,
              type: params[:period] || 'today'
            }
          }
        rescue => e
          Rails.logger.error "UsersController#scanning_stats error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to load scanning statistics',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/users/scan_history
      def scan_history
        begin
          page = [params[:page]&.to_i || 1, 1].max
          per_page = [[params[:per_page]&.to_i || 20, 1].max, 100].min
          
          if defined?(PackageTrackingEvent)
            events = PackageTrackingEvent.includes(:package, :user)
                                       .where(user: current_user)
                                       .order(created_at: :desc)
                                       .offset((page - 1) * per_page)
                                       .limit(per_page)
            
            total_count = PackageTrackingEvent.where(user: current_user).count
            
            serialized_events = events.map do |event|
              event.as_json(include_package: true)
            end
          else
            # Mock data for development
            serialized_events = []
            total_count = 0
          end

          render json: {
            success: true,
            data: serialized_events,
            pagination: {
              current_page: page,
              per_page: per_page,
              total_count: total_count,
              total_pages: (total_count / per_page.to_f).ceil,
              has_next: page * per_page < total_count,
              has_prev: page > 1
            }
          }
        rescue => e
          Rails.logger.error "UsersController#scan_history error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to load scan history',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/users/performance_metrics
      def performance_metrics
        begin
          period = parse_performance_period
          metrics = current_user.performance_metrics(period)
          
          render json: {
            success: true,
            data: metrics,
            period: period,
            user_role: current_user.primary_role
          }
        rescue => e
          Rails.logger.error "UsersController#performance_metrics error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to load performance metrics',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/users/dashboard_stats
      def dashboard_stats
        begin
          stats = {
            daily_stats: current_user.daily_scanning_stats,
            weekly_stats: current_user.weekly_scanning_stats,
            monthly_stats: current_user.monthly_scanning_stats,
            user_info: {
              role: current_user.primary_role,
              role_display: current_user.role_display_name,
              can_scan: current_user.can_scan_packages?,
              available_actions: current_user.available_actions,
              accessible_areas: current_user.accessible_areas.count,
              accessible_locations: current_user.accessible_locations.count
            }
          }

          # Add role-specific stats
          case current_user.primary_role
          when 'agent'
            stats[:role_specific] = {
              assigned_areas: current_user.agents.includes(:area).map { |a| a.area.name },
              labels_printed_today: get_labels_printed_today,
              packages_in_areas: get_packages_in_assigned_areas
            }
          when 'rider'
            stats[:role_specific] = {
              assigned_areas: current_user.riders.includes(:area).map { |r| r.area.name },
              deliveries_today: get_deliveries_today,
              collections_today: get_collections_today
            }
          when 'warehouse'
            stats[:role_specific] = {
              assigned_locations: current_user.warehouse_staff.includes(:location).map { |w| w.location.name },
              packages_processed_today: get_packages_processed_today,
              pending_packages: get_pending_warehouse_packages
            }
          end

          render json: {
            success: true,
            data: stats
          }
        rescue => e
          Rails.logger.error "UsersController#dashboard_stats error: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to load dashboard statistics',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      private

      def force_json_format
        request.format = :json
      end

      def user_params
        params.require(:user).permit(:email, :password, :name, :phone, :avatar)
      end

      def ensure_admin
        render json: { 
          success: false,
          error: "Access denied" 
        }, status: :forbidden unless current_user.has_role?(:admin)
      end

      def parse_date_range
        case params[:period]
        when 'week'
          1.week.ago..Time.current
        when 'month'
          1.month.ago..Time.current
        when 'custom'
          start_date = Date.parse(params[:start_date]) rescue Date.current
          end_date = Date.parse(params[:end_date]) rescue Date.current
          start_date.beginning_of_day..end_date.end_of_day
        else # 'today' or default
          Date.current.all_day
        end
      end

      def parse_performance_period
        case params[:period]
        when 'week'
          1.week
        when 'quarter'
          3.months
        when 'year'
          1.year
        else # 'month' or default
          1.month
        end
      end

      def get_labels_printed_today
        return 0 unless defined?(PackagePrintLog)
        
        PackagePrintLog.where(
          user: current_user,
          printed_at: Date.current.all_day
        ).count
      end

      def get_packages_in_assigned_areas
        return 0 unless current_user.agent?
        
        area_ids = current_user.accessible_areas
        Package.where(origin_area_id: area_ids)
               .or(Package.where(destination_area_id: area_ids))
               .where(state: ['submitted', 'in_transit'])
               .count
      end

      def get_deliveries_today
        return 0 unless defined?(PackageTrackingEvent)
        
        PackageTrackingEvent.where(
          user: current_user,
          event_type: 'delivered_by_rider',
          created_at: Date.current.all_day
        ).count
      end

      def get_collections_today
        return 0 unless defined?(PackageTrackingEvent)
        
        PackageTrackingEvent.where(
          user: current_user,
          event_type: 'collected_by_rider',
          created_at: Date.current.all_day
        ).count
      end

      def get_packages_processed_today
        return 0 unless defined?(PackageTrackingEvent)
        
        PackageTrackingEvent.where(
          user: current_user,
          event_type: 'processed_by_warehouse',
          created_at: Date.current.all_day
        ).count
      end

      def get_pending_warehouse_packages
        return 0 unless current_user.warehouse?
        
        location_ids = current_user.accessible_locations
        area_ids = Area.where(location_id: location_ids).pluck(:id)
        
        Package.where(origin_area_id: area_ids)
               .or(Package.where(destination_area_id: area_ids))
               .where(state: ['submitted', 'in_transit'])
               .count
      end
    end
  end
end