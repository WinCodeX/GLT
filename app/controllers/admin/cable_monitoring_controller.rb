# app/controllers/admin/cable_monitoring_controller.rb
class Admin::CableMonitoringController < AdminController
  # GET /admin/cable
  def index
    @stats = gather_cable_stats
    @connections = gather_connection_info
    @subscriptions = gather_subscription_info
  end
  
  # GET /admin/cable/connections (JSON)
  def connections
    connections_info = ActionCable.server.connections.map do |conn|
      {
        user_id: conn.current_user&.id,
        user_email: conn.current_user&.email,
        connection_identifier: conn.connection_identifier,
        connected_at: conn.started_at
      }
    end
    
    render json: {
      total_connections: connections_info.size,
      connections: connections_info,
      timestamp: Time.current.iso8601
    }
  end
  
  # GET /admin/cable/subscriptions (JSON)
  def subscriptions
    redis = ActionCable.server.pubsub.redis_connection_for_subscriptions
    keys = redis.keys("action_cable/*")
    
    subscriptions_by_channel = keys.group_by { |k| k.split("/")[1] }
                                    .transform_values(&:count)
    
    render json: {
      total_subscriptions: keys.count,
      by_channel: subscriptions_by_channel,
      all_keys: keys,
      timestamp: Time.current.iso8601
    }
  end
  
  # GET /admin/cable/stats (JSON)
  def stats
    render json: {
      connections: ActionCable.server.connections.size,
      worker_pool_size: ActionCable.server.worker_pool.size,
      redis_connected: redis_connected?,
      uptime: uptime_seconds,
      timestamp: Time.current.iso8601
    }
  end
  
  # POST /admin/cable/test_broadcast
  def test_broadcast
    channel = params[:channel] || 'test_channel'
    message = params[:message] || 'Test message from admin'
    
    ActionCable.server.broadcast(channel, {
      type: 'test',
      message: message,
      timestamp: Time.current.iso8601,
      from: 'admin_panel'
    })
    
    flash[:success] = "Test broadcast sent to channel: #{channel}"
    redirect_to admin_cable_path
  rescue => e
    flash[:error] = "Broadcast failed: #{e.message}"
    redirect_to admin_cable_path
  end
  
  private
  
  def gather_cable_stats
    {
      total_connections: safe_connection_count,
      worker_pool_size: safe_worker_pool_size,
      redis_connected: redis_connected?,
      uptime: uptime_seconds,
      redis_keys_count: redis_keys_count
    }
  rescue => e
    Rails.logger.error "Error gathering cable stats: #{e.message}"
    {
      total_connections: 0,
      worker_pool_size: 0,
      redis_connected: false,
      uptime: 0,
      redis_keys_count: 0
    }
  end
  
  def gather_connection_info
    return [] unless ActionCable.server.respond_to?(:connections)
    
    ActionCable.server.connections.map do |conn|
      {
        user: conn.respond_to?(:current_user) ? conn.current_user : nil,
        connection_identifier: conn.respond_to?(:connection_identifier) ? conn.connection_identifier : 'unknown',
        started_at: conn.respond_to?(:started_at) ? conn.started_at : Time.current
      }
    end
  rescue => e
    Rails.logger.error "Error gathering connections: #{e.message}"
    []
  end
  
  def gather_subscription_info
    return {} unless ActionCable.server.respond_to?(:pubsub)
    
    redis = ActionCable.server.pubsub.redis_connection_for_subscriptions
    keys = redis.keys("action_cable/*")
    
    keys.group_by { |k| k.split("/")[1] }.transform_values(&:count)
  rescue => e
    Rails.logger.error "Error gathering subscriptions: #{e.message}"
    {}
  end
  
  def safe_connection_count
    return 0 unless ActionCable.server.respond_to?(:connections)
    ActionCable.server.connections.size
  rescue
    0
  end
  
  def safe_worker_pool_size
    # worker_pool doesn't have a size method, return configured value
    return 4 # Default worker pool size in Rails
  rescue
    4
  end
  
  def redis_connected?
    return false unless ActionCable.server.respond_to?(:pubsub)
    ActionCable.server.pubsub.redis_connection_for_subscriptions.ping == "PONG"
  rescue
    false
  end
  
  def redis_keys_count
    return 0 unless ActionCable.server.respond_to?(:pubsub)
    ActionCable.server.pubsub.redis_connection_for_subscriptions.keys("action_cable/*").count
  rescue
    0
  end
  
  def uptime_seconds
    return 0 unless ActionCable.server.respond_to?(:started_at)
    (Time.current - ActionCable.server.started_at).to_i
  rescue
    0
  end
end