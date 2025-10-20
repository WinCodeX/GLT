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
      user_subscriptions = extract_user_subscriptions(conn)
      
      {
        user_id: conn.current_user&.id,
        user_email: conn.current_user&.email,
        connection_identifier: conn.connection_identifier,
        connected_at: conn.started_at,
        subscriptions: user_subscriptions,
        subscription_count: user_subscriptions.count
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
    subscription_data = gather_all_subscriptions
    
    render json: {
      total_subscriptions: subscription_data[:total],
      by_channel: subscription_data[:by_channel],
      by_user: subscription_data[:by_user],
      active_streams: subscription_data[:active_streams],
      timestamp: Time.current.iso8601
    }
  end
  
  # GET /admin/cable/stats (JSON)
  def stats
    render json: {
      connections: ActionCable.server.connections.size,
      worker_pool_size: safe_worker_pool_size,
      redis_connected: redis_connected?,
      total_subscriptions: count_all_subscriptions,
      active_pubsub_channels: count_pubsub_channels,
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
      total_subscriptions: count_all_subscriptions,
      active_pubsub_channels: count_pubsub_channels
    }
  rescue => e
    Rails.logger.error "Error gathering cable stats: #{e.message}"
    {
      total_connections: 0,
      worker_pool_size: 0,
      redis_connected: false,
      total_subscriptions: 0,
      active_pubsub_channels: 0
    }
  end
  
  def gather_connection_info
    return [] unless ActionCable.server.respond_to?(:connections)
    
    ActionCable.server.connections.map do |conn|
      {
        user: conn.respond_to?(:current_user) ? conn.current_user : nil,
        connection_identifier: conn.respond_to?(:connection_identifier) ? conn.connection_identifier : 'unknown',
        started_at: conn.respond_to?(:started_at) ? conn.started_at : Time.current,
        subscriptions: extract_user_subscriptions(conn)
      }
    end
  rescue => e
    Rails.logger.error "Error gathering connections: #{e.message}"
    []
  end
  
  def gather_subscription_info
    data = gather_all_subscriptions
    data[:by_channel]
  rescue => e
    Rails.logger.error "Error gathering subscriptions: #{e.message}"
    {}
  end
  
  def gather_all_subscriptions
    by_channel = Hash.new(0)
    by_user = Hash.new { |h, k| h[k] = [] }
    all_streams = []
    
    # Iterate through each connection and extract their subscriptions
    ActionCable.server.connections.each do |conn|
      user_id = conn.current_user&.id
      streams = extract_user_subscriptions(conn)
      
      streams.each do |stream_name|
        by_channel[stream_name] += 1
        all_streams << stream_name unless all_streams.include?(stream_name)
        
        if user_id
          by_user[user_id] << stream_name unless by_user[user_id].include?(stream_name)
        end
      end
    end
    
    {
      total: by_channel.values.sum,
      by_channel: by_channel,
      by_user: by_user,
      active_streams: all_streams
    }
  rescue => e
    Rails.logger.error "Error gathering all subscriptions: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    {
      total: 0,
      by_channel: {},
      by_user: {},
      active_streams: []
    }
  end
  
  def extract_user_subscriptions(connection)
    streams = []
    
    # Method 1: Check @subscriptions instance variable
    if connection.instance_variable_defined?(:@subscriptions)
      subscriptions = connection.instance_variable_get(:@subscriptions)
      
      if subscriptions.respond_to?(:each)
        subscriptions.each do |identifier, subscription|
          # Extract stream names from each subscription
          if subscription.respond_to?(:streams)
            streams.concat(subscription.streams.to_a)
          elsif subscription.instance_variable_defined?(:@streams)
            subscription_streams = subscription.instance_variable_get(:@streams)
            streams.concat(subscription_streams.to_a) if subscription_streams
          end
        end
      end
    end
    
    # Method 2: Try to access pubsub directly
    if streams.empty?
      begin
        # Get Redis PUBSUB channels that match this connection
        redis = ActionCable.server.pubsub.redis_connection_for_subscriptions
        all_channels = redis.pubsub('channels', '*')
        
        # Filter channels that might belong to this user
        user_id = connection.current_user&.id
        if user_id
          user_channels = all_channels.select do |channel|
            channel.include?(user_id.to_s)
          end
          streams.concat(user_channels)
        end
      rescue => e
        Rails.logger.debug "Could not extract subscriptions via pubsub: #{e.message}"
      end
    end
    
    streams.uniq
  rescue => e
    Rails.logger.error "Error extracting user subscriptions: #{e.message}"
    []
  end
  
  def count_all_subscriptions
    ActionCable.server.connections.sum do |conn|
      extract_user_subscriptions(conn).count
    end
  rescue => e
    Rails.logger.error "Error counting subscriptions: #{e.message}"
    0
  end
  
  def count_pubsub_channels
    return 0 unless ActionCable.server.respond_to?(:pubsub)
    
    redis = ActionCable.server.pubsub.redis_connection_for_subscriptions
    redis.pubsub('channels', '*').count
  rescue => e
    Rails.logger.error "Error counting PUBSUB channels: #{e.message}"
    0
  end
  
  def safe_connection_count
    return 0 unless ActionCable.server.respond_to?(:connections)
    ActionCable.server.connections.size
  rescue => e
    Rails.logger.error "Error getting connection count: #{e.message}"
    0
  end
  
  def safe_worker_pool_size
    ActionCable.server.config.worker_pool_size || 4
  rescue
    4
  end
  
  def redis_connected?
    return false unless ActionCable.server.respond_to?(:pubsub)
    ActionCable.server.pubsub.redis_connection_for_subscriptions.ping == "PONG"
  rescue => e
    Rails.logger.error "Redis connection check failed: #{e.message}"
    false
  end

  def uptime_seconds
    0
  end
end  # Only one 'end' here to close the class