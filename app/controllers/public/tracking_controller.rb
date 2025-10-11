# app/controllers/public/tracking_controller.rb
class Public::TrackingController < ApplicationController
  # Skip authentication for public access
  skip_before_action :authenticate_user!, raise: false
  
  # Find package before actions
  before_action :find_package, only: [:show, :status, :timeline]
  
  # Use custom layout
  layout 'public_tracking'

  # Main tracking page
  def show
    unless @package
      render :not_found, status: :not_found and return
    end

    @tracking_events = @package.tracking_events
                               .includes(:user)
                               .order(created_at: :desc)
    
    @journey_timeline = build_journey_timeline(@package)
    
    respond_to do |format|
      format.html
      format.json { render json: package_tracking_json }
    end
  rescue => e
    Rails.logger.error "Error in public tracking show: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render :not_found, status: :not_found
  end

  # Status endpoint (JSON only)
  def status
    unless @package
      render json: { error: 'Package not found' }, status: :not_found and return
    end

    render json: {
      code: @package.code,
      state: @package.state,
      state_display: @package.state.humanize,
      current_location: @package.delivery_location || @package.pickup_location,
      estimated_delivery: estimate_delivery_time(@package),
      last_updated: @package.updated_at,
      is_fragile: @package.fragile_delivery?,
      delivery_type: @package.delivery_type_display
    }
  rescue => e
    Rails.logger.error "Error in public tracking status: #{e.message}"
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end

  # Timeline endpoint (JSON only)
  def timeline
    unless @package
      render json: { error: 'Package not found' }, status: :not_found and return
    end

    render json: {
      package_code: @package.code,
      timeline: build_journey_timeline(@package)
    }
  rescue => e
    Rails.logger.error "Error in public tracking timeline: #{e.message}"
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end

  private

  def find_package
    @package = Package.find_by(code: params[:code])
    
    if @package.nil?
      Rails.logger.info "Package not found: #{params[:code]}"
    else
      Rails.logger.info "Package found: #{@package.code} (ID: #{@package.id})"
    end
  end

  def build_journey_timeline(package)
    return [] unless package
    
    timeline = []
    
    # 1. Package created
    timeline << {
      icon: 'package',
      title: 'Package created and details submitted',
      description: "Cost: KES #{package.cost}",
      timestamp: package.created_at,
      status: 'completed'
    }

    # 2. Payment status
    if package.paid?
      payment_event = package.tracking_events.find_by(event_type: 'payment_confirmed')
      timeline << {
        icon: 'credit-card',
        title: 'Payment confirmed',
        description: "Payment method: #{package.payment_method&.upcase || 'M-Pesa'}",
        timestamp: payment_event&.created_at || package.updated_at,
        status: 'completed'
      }
    end

    # 3. Package submitted
    if package.submitted? || package.in_transit? || package.delivered? || package.collected?
      submitted_event = package.tracking_events.find_by(event_type: 'submitted')
      timeline << {
        icon: 'check-circle',
        title: 'Package submitted for delivery',
        description: 'Package is ready for pickup by rider',
        timestamp: submitted_event&.created_at || package.updated_at,
        status: 'completed'
      }
    end

    # 4. In transit
    if package.in_transit? || package.delivered? || package.collected?
      transit_event = package.tracking_events.find_by(event_type: 'in_transit')
      timeline << {
        icon: 'truck',
        title: 'Package in transit',
        description: 'Your package is on its way',
        timestamp: transit_event&.created_at || package.updated_at,
        status: 'completed'
      }
    end

    # 5. Out for delivery
    if package.delivered? || package.collected?
      out_for_delivery_event = package.tracking_events.find_by(event_type: 'out_for_delivery')
      if out_for_delivery_event
        timeline << {
          icon: 'navigation',
          title: 'Out for delivery',
          description: 'Package is out for delivery',
          timestamp: out_for_delivery_event.created_at,
          status: 'completed'
        }
      end
    end

    # 6. Delivered
    if package.delivered? || package.collected?
      delivered_event = package.tracking_events.find_by(event_type: 'delivered')
      timeline << {
        icon: 'home',
        title: 'Package delivered',
        description: 'Package delivered successfully',
        timestamp: delivered_event&.created_at || package.updated_at,
        status: 'completed'
      }
    end

    # 7. Collected (if applicable)
    if package.collected?
      collected_event = package.tracking_events.find_by(event_type: 'collected')
      timeline << {
        icon: 'check',
        title: 'Package collected',
        description: 'Package collected by recipient',
        timestamp: collected_event&.created_at || package.updated_at,
        status: 'completed'
      }
    end

    # 8. Rejected (if applicable)
    if package.rejected?
      timeline << {
        icon: 'x-circle',
        title: package.auto_rejected? ? 'Package auto-rejected' : 'Package rejected',
        description: package.rejection_reason || 'Package was rejected',
        timestamp: package.rejected_at,
        status: 'rejected'
      }
    end

    # Sort by timestamp (oldest first for proper timeline order)
    timeline.sort_by { |event| event[:timestamp] }
  end

  def estimate_delivery_time(package)
    return nil unless package
    
    case package.state
    when 'pending_unpaid', 'pending'
      nil
    when 'submitted'
      package.created_at + 2.days
    when 'in_transit'
      package.created_at + 1.day
    when 'delivered', 'collected'
      package.updated_at
    else
      package.created_at + 3.days
    end
  end

  def package_tracking_json
    {
      package: {
        code: @package.code,
        state: @package.state,
        state_display: @package.state.humanize,
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
        delivery_location: @package.delivery_location || @package.pickup_location,
        is_fragile: @package.fragile_delivery?,
        is_collection: @package.collection_delivery?,
        package_size: @package.package_size_display,
        created_at: @package.created_at,
        updated_at: @package.updated_at,
        estimated_delivery: estimate_delivery_time(@package)
      },
      timeline: @journey_timeline,
      tracking_url: public_package_tracking_url(@package.code)
    }
  rescue => e
    Rails.logger.error "Error building package tracking JSON: #{e.message}"
    { error: 'Error building tracking data' }
  end
end