# app/controllers/public/tracking_controller.rb
module Public
  class TrackingController < ApplicationController
    skip_before_action :authenticate_user!, raise: false
    layout 'public_tracking'

    def show
      @package = Package.find_by(code: params[:code])
      
      if @package.nil?
        render :not_found, status: :not_found
        return
      end

      @tracking_events = @package.tracking_events
                                 .includes(:user)
                                 .order(created_at: :desc)
      
      @journey_timeline = build_journey_timeline(@package)
      
      respond_to do |format|
        format.html
        format.json { render json: package_tracking_json }
      end
    end

    def status
      @package = Package.find_by(code: params[:code])
      
      if @package.nil?
        render json: { error: 'Package not found' }, status: :not_found
        return
      end

      render json: {
        code: @package.code,
        state: @package.state,
        state_display: @package.state.humanize,
        current_location: @package.delivery_location || @package.pickup_location,
        estimated_delivery: @package.created_at + 3.days,
        last_updated: @package.updated_at
      }
    end

    def timeline
      @package = Package.find_by(code: params[:code])
      
      if @package.nil?
        render json: { error: 'Package not found' }, status: :not_found
        return
      end

      render json: {
        timeline: build_journey_timeline(@package)
      }
    end

    private

    def build_journey_timeline(package)
      timeline = []
      
      # Package created
      timeline << {
        icon: 'package',
        title: 'Package created and details submitted',
        description: "Cost: KES #{package.cost}",
        timestamp: package.created_at,
        status: 'completed'
      }

      # Payment status
      if package.paid?
        timeline << {
          icon: 'credit-card',
          title: 'Payment confirmed',
          description: "Payment method: #{package.payment_method&.upcase || 'M-Pesa'}",
          timestamp: package.updated_at,
          status: 'completed'
        }
      end

      # Package submitted
      if package.submitted? || package.in_transit? || package.delivered? || package.collected?
        timeline << {
          icon: 'check-circle',
          title: 'Package submitted for delivery',
          description: 'Package is ready for pickup by rider',
          timestamp: package.tracking_events.find_by(event_type: 'submitted')&.created_at || package.updated_at,
          status: 'completed'
        }
      end

      # In transit
      if package.in_transit? || package.delivered? || package.collected?
        timeline << {
          icon: 'truck',
          title: 'Package in transit',
          description: 'Your package is on its way',
          timestamp: package.tracking_events.find_by(event_type: 'in_transit')&.created_at || package.updated_at,
          status: 'completed'
        }
      end

      # Delivered
      if package.delivered? || package.collected?
        timeline << {
          icon: 'home',
          title: 'Package delivered',
          description: 'Package delivered successfully',
          timestamp: package.tracking_events.find_by(event_type: 'delivered')&.created_at || package.updated_at,
          status: 'completed'
        }
      end

      # Rejected
      if package.rejected?
        timeline << {
          icon: 'x-circle',
          title: 'Package rejected',
          description: package.rejection_reason || 'Package was rejected',
          timestamp: package.rejected_at,
          status: 'rejected'
        }
      end

      timeline
    end

    def package_tracking_json
      {
        package: {
          code: @package.code,
          state: @package.state,
          sender: {
            name: @package.sender_name,
            phone: @package.sender_phone
          },
          receiver: {
            name: @package.receiver_name,
            phone: @package.receiver_phone
          },
          cost: @package.cost,
          delivery_type: @package.delivery_type_display,
          delivery_location: @package.delivery_location,
          is_fragile: @package.fragile_delivery?,
          created_at: @package.created_at
        },
        timeline: @journey_timeline
      }
    end
  end
end