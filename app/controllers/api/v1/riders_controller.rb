# app/controllers/api/v1/riders_controller.rb
module Api
  module V1
    class RidersController < ApplicationController
      before_action :authenticate_user!
      before_action :ensure_rider_or_admin
      before_action :force_json_format
      before_action :set_rider, only: [:location, :offline, :stats, :active_deliveries]

      # GET /api/v1/riders/active_deliveries
      def active_deliveries
        begin
          deliveries = get_rider_deliveries
          
          serialized_data = PackageSerializer.new(deliveries, {
            params: { 
              include_business: true,
              url_helper: self
            }
          }).serializable_hash

          render json: {
            success: true,
            data: serialized_data[:data]&.map { |pkg| pkg[:attributes] } || [],
            stats: {
              total: deliveries.count,
              in_transit: deliveries.where(state: 'in_transit').count,
              submitted: deliveries.where(state: 'submitted').count,
              delivered_today: get_delivered_today_count
            },
            rider_info: {
              status: current_user.online? ? 'online' : 'offline',
              location_enabled: @rider&.location_enabled || false,
              available_for_assignment: @rider&.available_for_assignment || false
            }
          }
        rescue => e
          Rails.logger.error "RidersController#active_deliveries error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load active deliveries',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/riders/location
      def location
        begin
          location_params = params.require(:rider).permit(
            :latitude, :longitude, :accuracy, :heading, :speed, :timestamp
          )

          # Update rider location
          if @rider
            @rider.update!(
              current_latitude: location_params[:latitude],
              current_longitude: location_params[:longitude],
              location_accuracy: location_params[:accuracy],
              location_updated_at: Time.current,
              location_enabled: true
            )
          end

          # Broadcast location update to relevant channels
          broadcast_rider_location_update(location_params)

          render json: {
            success: true,
            message: 'Location updated successfully',
            data: {
              latitude: location_params[:latitude],
              longitude: location_params[:longitude],
              accuracy: location_params[:accuracy],
              timestamp: Time.current.iso8601
            }
          }
        rescue ActionController::ParameterMissing => e
          render json: {
            success: false,
            message: 'Missing required location parameters',
            error: e.message
          }, status: :bad_request
        rescue => e
          Rails.logger.error "RidersController#location error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to update location',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/riders/offline
      def offline
        begin
          current_user.mark_offline! if current_user.respond_to?(:mark_offline!)
          
          if @rider
            @rider.update!(
              location_enabled: false,
              available_for_assignment: false
            )
          end

          # Broadcast offline status
          broadcast_rider_status_change('offline')

          render json: {
            success: true,
            message: 'Rider status set to offline',
            data: {
              status: 'offline',
              timestamp: Time.current.iso8601
            }
          }
        rescue => e
          Rails.logger.error "RidersController#offline error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to set offline status',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/riders/reports
      def create_report
        begin
          report_params = params.require(:report).permit(
            :issue_type, :description, location: [:latitude, :longitude]
          )

          report = RiderReport.create!(
            user: current_user,
            rider: @rider,
            issue_type: report_params[:issue_type],
            description: report_params[:description],
            location_latitude: report_params.dig(:location, :latitude),
            location_longitude: report_params.dig(:location, :longitude),
            reported_at: Time.current,
            status: 'pending'
          )

          # Get all active deliveries and their senders
          affected_packages = get_rider_deliveries
          affected_sender_ids = affected_packages.pluck(:user_id).uniq
          
          # Broadcast report to admin dashboard
          broadcast_rider_report(report)

          # ENHANCED: Broadcast to all affected package senders
          broadcast_to_affected_senders(report, affected_packages, affected_sender_ids)

          # Create notification for admins
          create_report_notification(report)

          # Create notifications for affected senders
          create_sender_notifications(report, affected_packages, affected_sender_ids)

          render json: {
            success: true,
            message: 'Report submitted successfully',
            data: {
              id: report.id,
              issue_type: report.issue_type,
              status: report.status,
              created_at: report.created_at.iso8601,
              affected_packages: affected_packages.count,
              affected_senders: affected_sender_ids.count
            }
          }, status: :created
        rescue ActionController::ParameterMissing => e
          render json: {
            success: false,
            message: 'Missing required report parameters',
            error: e.message
          }, status: :bad_request
        rescue => e
          Rails.logger.error "RidersController#create_report error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to submit report',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/riders/reports
      def reports
        begin
          page = [params[:page]&.to_i || 1, 1].max
          per_page = [[params[:per_page]&.to_i || 20, 1].max, 100].min
          
          reports = RiderReport.where(user: current_user)
                              .order(created_at: :desc)
                              .offset((page - 1) * per_page)
                              .limit(per_page)
          
          total_count = RiderReport.where(user: current_user).count

          serialized_reports = reports.map do |report|
            {
              id: report.id,
              issue_type: report.issue_type,
              description: report.description,
              status: report.status,
              created_at: report.created_at.iso8601,
              resolved_at: report.resolved_at&.iso8601,
              location: report.location_latitude && report.location_longitude ? {
                latitude: report.location_latitude,
                longitude: report.location_longitude
              } : nil
            }
          end

          render json: {
            success: true,
            data: serialized_reports,
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
          Rails.logger.error "RidersController#reports error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load reports',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/riders/stats
      def stats
        begin
          today_start = Time.current.beginning_of_day
          week_start = 1.week.ago
          month_start = 1.month.ago

          stats_data = {
            deliveries: {
              today: get_deliveries_count(today_start),
              this_week: get_deliveries_count(week_start),
              this_month: get_deliveries_count(month_start),
              total: get_deliveries_count(nil)
            },
            collections: {
              today: get_collections_count(today_start),
              this_week: get_collections_count(week_start),
              this_month: get_collections_count(month_start),
              total: get_collections_count(nil)
            },
            active_deliveries: get_rider_deliveries.count,
            pending_collections: get_pending_collections_count,
            rating: @rider&.rating || 0,
            total_distance_today: @rider&.distance_today || 0,
            online_time_today: calculate_online_time_today
          }

          render json: {
            success: true,
            data: stats_data,
            rider_info: {
              name: current_user.display_name || current_user.name,
              status: current_user.online? ? 'online' : 'offline',
              areas: get_rider_areas,
              location_enabled: @rider&.location_enabled || false
            }
          }
        rescue => e
          Rails.logger.error "RidersController#stats error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load statistics',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/riders/areas
      def areas
        begin
          areas = get_rider_areas

          render json: {
            success: true,
            data: areas.map do |area|
              {
                id: area.id,
                name: area.name,
                location_name: area.location&.name,
                active_packages: Package.where(
                  destination_area_id: area.id,
                  state: ['submitted', 'in_transit']
                ).count
              }
            end
          }
        rescue => e
          Rails.logger.error "RidersController#areas error: #{e.message}"
          render json: { 
            success: false, 
            message: 'Failed to load assigned areas',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      private

      def force_json_format
        request.format = :json
      end

      def ensure_rider_or_admin
        unless current_user.has_role?(:rider) || current_user.has_role?(:admin)
          render json: { 
            success: false,
            message: 'Access denied. Rider role required.' 
          }, status: :forbidden
        end
      end

      def set_rider
        @rider = Rider.find_by(user_id: current_user.id) if defined?(Rider)
      end

      def get_rider_deliveries
        area_ids = current_user.accessible_areas if current_user.respond_to?(:accessible_areas)
        area_ids ||= []

        Package.where(state: ['submitted', 'in_transit'])
               .where(destination_area_id: area_ids)
               .or(Package.where(state: ['submitted', 'in_transit'], origin_area_id: area_ids))
               .includes(:origin_area, :destination_area, :business, :user)
               .order(created_at: :desc)
      end

      def get_delivered_today_count
        return 0 unless defined?(PackageTrackingEvent)
        
        PackageTrackingEvent.where(
          user: current_user,
          event_type: 'delivered_by_rider',
          created_at: Time.current.beginning_of_day..Time.current
        ).count
      end

      def get_deliveries_count(start_time)
        return 0 unless defined?(PackageTrackingEvent)
        
        query = PackageTrackingEvent.where(
          user: current_user,
          event_type: 'delivered_by_rider'
        )
        
        query = query.where('created_at >= ?', start_time) if start_time
        query.count
      end

      def get_collections_count(start_time)
        return 0 unless defined?(PackageTrackingEvent)
        
        query = PackageTrackingEvent.where(
          user: current_user,
          event_type: 'collected_by_rider'
        )
        
        query = query.where('created_at >= ?', start_time) if start_time
        query.count
      end

      def get_pending_collections_count
        area_ids = current_user.accessible_areas if current_user.respond_to?(:accessible_areas)
        area_ids ||= []

        Package.where(state: 'submitted', origin_area_id: area_ids).count
      end

      def get_rider_areas
        return [] unless current_user.respond_to?(:accessible_areas)
        
        area_ids = current_user.accessible_areas
        Area.where(id: area_ids).includes(:location)
      end

      def calculate_online_time_today
        # This would need to be tracked in a rider_sessions table
        # For now, return a placeholder
        0
      end

      def broadcast_rider_location_update(location_params)
        begin
          ActionCable.server.broadcast(
            "rider_#{current_user.id}_location",
            {
              type: 'location_update',
              rider_id: current_user.id,
              rider_name: current_user.display_name || current_user.name,
              location: {
                latitude: location_params[:latitude],
                longitude: location_params[:longitude],
                accuracy: location_params[:accuracy],
                heading: location_params[:heading],
                speed: location_params[:speed]
              },
              timestamp: Time.current.iso8601
            }
          )

          # Broadcast to admin dashboard
          ActionCable.server.broadcast(
            'riders_dashboard',
            {
              type: 'rider_location_update',
              rider_id: current_user.id,
              rider_name: current_user.display_name || current_user.name,
              location: {
                latitude: location_params[:latitude],
                longitude: location_params[:longitude]
              },
              timestamp: Time.current.iso8601
            }
          )

          Rails.logger.info "📍 Broadcasted location update for rider #{current_user.id}"
        rescue => e
          Rails.logger.error "Failed to broadcast location update: #{e.message}"
        end
      end

      def broadcast_rider_status_change(status)
        begin
          ActionCable.server.broadcast(
            "rider_#{current_user.id}_status",
            {
              type: 'status_change',
              rider_id: current_user.id,
              rider_name: current_user.display_name || current_user.name,
              status: status,
              timestamp: Time.current.iso8601
            }
          )

          # Broadcast to admin dashboard
          ActionCable.server.broadcast(
            'riders_dashboard',
            {
              type: 'rider_status_change',
              rider_id: current_user.id,
              rider_name: current_user.display_name || current_user.name,
              status: status,
              timestamp: Time.current.iso8601
            }
          )

          Rails.logger.info "📡 Broadcasted status change for rider #{current_user.id}: #{status}"
        rescue => e
          Rails.logger.error "Failed to broadcast status change: #{e.message}"
        end
      end

      def broadcast_rider_report(report)
        begin
          ActionCable.server.broadcast(
            'riders_dashboard',
            {
              type: 'new_rider_report',
              report: {
                id: report.id,
                rider_id: current_user.id,
                rider_name: current_user.display_name || current_user.name,
                issue_type: report.issue_type,
                description: report.description,
                status: report.status,
                location: report.location_latitude && report.location_longitude ? {
                  latitude: report.location_latitude,
                  longitude: report.location_longitude
                } : nil,
                created_at: report.created_at.iso8601
              },
              timestamp: Time.current.iso8601
            }
          )

          # Broadcast to support channel
          ActionCable.server.broadcast(
            'support_dashboard',
            {
              type: 'rider_issue_reported',
              report: {
                id: report.id,
                rider_id: current_user.id,
                rider_name: current_user.display_name || current_user.name,
                issue_type: report.issue_type,
                severity: determine_issue_severity(report.issue_type),
                status: report.status,
                created_at: report.created_at.iso8601
              },
              timestamp: Time.current.iso8601
            }
          )

          Rails.logger.info "🚨 Broadcasted new rider report #{report.id} from rider #{current_user.id}"
        rescue => e
          Rails.logger.error "Failed to broadcast rider report: #{e.message}"
        end
      end

      # NEW: Broadcast to all affected package senders
      def broadcast_to_affected_senders(report, affected_packages, affected_sender_ids)
        begin
          return if affected_sender_ids.empty?

          rider_name = current_user.display_name || current_user.name
          issue_message = generate_issue_message(report.issue_type)
          severity = determine_issue_severity(report.issue_type)

          # Broadcast to each affected sender
          affected_sender_ids.each do |sender_id|
            # Get sender's packages
            sender_packages = affected_packages.where(user_id: sender_id)
            package_codes = sender_packages.pluck(:code)

            # Broadcast to sender's notification channel
            ActionCable.server.broadcast(
              "user_notifications_#{sender_id}",
              {
                type: 'rider_issue_notification',
                notification_type: 'rider_report',
                rider_id: current_user.id,
                rider_name: rider_name,
                issue_type: report.issue_type,
                severity: severity,
                message: issue_message,
                affected_packages: package_codes,
                package_count: package_codes.count,
                status: report.status,
                estimated_impact: estimate_delivery_impact(report.issue_type),
                created_at: report.created_at.iso8601,
                timestamp: Time.current.iso8601
              }
            )

            # Also broadcast to sender's packages channel
            ActionCable.server.broadcast(
              "user_packages_#{sender_id}",
              {
                type: 'delivery_delay_notification',
                reason: report.issue_type,
                rider_name: rider_name,
                affected_packages: package_codes,
                severity: severity,
                message: issue_message,
                timestamp: Time.current.iso8601
              }
            )
          end

          # Broadcast to each affected package's tracking channel
          affected_packages.each do |package|
            ActionCable.server.broadcast(
              "package_#{package.id}_updates",
              {
                type: 'delivery_issue_reported',
                package_code: package.code,
                rider_id: current_user.id,
                rider_name: rider_name,
                issue_type: report.issue_type,
                severity: severity,
                message: issue_message,
                estimated_impact: estimate_delivery_impact(report.issue_type),
                timestamp: Time.current.iso8601
              }
            )
          end

          Rails.logger.info "📨 Broadcasted rider report #{report.id} to #{affected_sender_ids.count} senders (#{affected_packages.count} packages)"
        rescue => e
          Rails.logger.error "Failed to broadcast to affected senders: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
        end
      end

      def create_report_notification(report)
        return unless defined?(Notification)
        
        begin
          # Notify all admins
          admin_users = User.with_role(:admin)
          
          admin_users.each do |admin|
            Notification.create!(
              user: admin,
              notification_type: 'rider_report',
              title: "Rider Issue: #{report.issue_type.humanize}",
              message: "#{current_user.display_name || current_user.name} reported a #{report.issue_type} issue",
              data: {
                report_id: report.id,
                rider_id: current_user.id,
                rider_name: current_user.display_name || current_user.name,
                issue_type: report.issue_type,
                severity: determine_issue_severity(report.issue_type)
              }
            )
          end

          Rails.logger.info "Created notifications for rider report #{report.id}"
        rescue => e
          Rails.logger.error "Failed to create report notifications: #{e.message}"
        end
      end

      # NEW: Create notifications for affected senders
      def create_sender_notifications(report, affected_packages, affected_sender_ids)
        return unless defined?(Notification)
        return if affected_sender_ids.empty?

        begin
          rider_name = current_user.display_name || current_user.name
          issue_message = generate_issue_message(report.issue_type)
          severity = determine_issue_severity(report.issue_type)

          affected_sender_ids.each do |sender_id|
            sender_packages = affected_packages.where(user_id: sender_id)
            package_codes = sender_packages.pluck(:code).join(', ')

            notification_title = case severity
            when 'critical'
              "⚠️ Critical: Delivery Issue Reported"
            when 'high'
              "⚠️ Delivery Delay Alert"
            when 'medium'
              "📦 Delivery Update"
            else
              "ℹ️ Delivery Status Update"
            end

            Notification.create!(
              user_id: sender_id,
              notification_type: 'delivery_issue',
              title: notification_title,
              message: "Your rider #{rider_name} reported: #{issue_message}. Affected packages: #{package_codes}",
              data: {
                report_id: report.id,
                rider_id: current_user.id,
                rider_name: rider_name,
                issue_type: report.issue_type,
                severity: severity,
                affected_packages: sender_packages.pluck(:id),
                package_codes: sender_packages.pluck(:code),
                estimated_impact: estimate_delivery_impact(report.issue_type),
                created_at: report.created_at.iso8601
              },
              priority: severity == 'critical' ? 'high' : 'normal'
            )
          end

          Rails.logger.info "Created #{affected_sender_ids.count} sender notifications for rider report #{report.id}"
        rescue => e
          Rails.logger.error "Failed to create sender notifications: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
        end
      end

      def determine_issue_severity(issue_type)
        case issue_type.to_s
        when 'accident'
          'critical'
        when 'mechanical', 'weather'
          'high'
        when 'fuel'
          'medium'
        else
          'low'
        end
      end

      # NEW: Generate user-friendly issue message
      def generate_issue_message(issue_type)
        case issue_type.to_s
        when 'accident'
          "An accident has been reported. Your delivery may be significantly delayed. We're working to resolve this urgently."
        when 'mechanical'
          "A mechanical issue with the delivery vehicle has been reported. Your delivery may be delayed while we address this."
        when 'weather'
          "Severe weather conditions are affecting deliveries. Your package may be delayed for safety reasons."
        when 'fuel'
          "The rider is experiencing a fuel issue. This may cause a brief delay in your delivery."
        when 'other'
          "An issue has been reported that may affect your delivery. We're working to resolve it quickly."
        else
          "A delivery issue has been reported. We'll keep you updated on the status."
        end
      end

      # NEW: Estimate delivery impact based on issue type
      def estimate_delivery_impact(issue_type)
        case issue_type.to_s
        when 'accident'
          {
            delay_estimate: '2-6 hours',
            likelihood: 'high',
            action_required: 'Package may be reassigned to another rider',
            customer_action: 'No action needed. We will notify you of updates.'
          }
        when 'mechanical'
          {
            delay_estimate: '1-3 hours',
            likelihood: 'medium',
            action_required: 'Vehicle repair or rider reassignment',
            customer_action: 'No action needed. Delivery will resume shortly.'
          }
        when 'weather'
          {
            delay_estimate: '30 minutes - 2 hours',
            likelihood: 'medium',
            action_required: 'Waiting for weather to improve',
            customer_action: 'No action needed. Delivery will proceed when safe.'
          }
        when 'fuel'
          {
            delay_estimate: '15-45 minutes',
            likelihood: 'low',
            action_required: 'Refueling in progress',
            customer_action: 'No action needed. Minor delay expected.'
          }
        else
          {
            delay_estimate: 'To be determined',
            likelihood: 'unknown',
            action_required: 'Under investigation',
            customer_action: 'We will update you shortly.'
          }
        end
      end
    end
  end
end