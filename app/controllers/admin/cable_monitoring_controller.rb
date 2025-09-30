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
        connected_at: conn.started_at,
        subscriptions: extract_connection_subscriptions(conn)
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
    subscriptions_data = gather_detailed_subscriptions
    
    render json: {
      total_subscriptions: subscriptions_data[:total],
      by_channel: subscriptions_data[:by_channel],
      by_user: subscriptions_data[:by_user],
      all_channels: subscriptions_data[:all_channels],
      redis_patterns_checked: subscriptions_data[:patterns_checked],
      timestamp: Time.current.iso8601
    }
  end
  
  # GET /admin/cable/stats (JSON)
  def stats
    render json: {
      connections: ActionCable.server.connections.size,
      worker_pool_size: safe_worker_pool_size,
      redis_connected: redis_connected?,
      uptime: uptime_seconds,
      active_subscriptions: count_active_subscriptions,
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
  
  # GET /admin/cable/debug (JSON) - Debug endpoint to inspect Redis
  def debug
    redis = ActionCable.server.pubsub.redis_connection_for_subscriptions
    
    # Try multiple patterns to find ActionCable data
    patterns = [
      'action_cable/*',
      '_action_cable_internal:*',
      'action_cable:*',
      '*action_cable*'
    ]
    
    debug_info = {
      redis_info: redis.info('server'),
      patterns_searched: {}
    }
    
    patterns.each do |pattern|
      keys = redis.keys(pattern)
      debug_info[:patterns_searched][pattern] = {
        count: keys.count,
        sample_keys: keys.first(5)
      }
    end
    
    # Check PUBSUB channels
    pubsub_channels = redis.pubsub('channels', '*')
    debug_info[:pubsub_channels] = {
      count: pubsub_channels.count,
      channels: pubsub_channels.first(20)
    }
    
    render json: debug_info
  rescue => e
    render json: { error: e.message, backtrace: e.backtrace.first(5) }, status: 500
  end
  
  private
  
  def gather_cable_stats
    {
      total_connections: safe_connection_count,
      worker_pool_size: safe_worker_pool_size,
      redis_connected: redis_connected?,
      uptime: uptime_seconds,
      active_subscriptions: count_active_subscriptions,
      redis_patterns_found: count_redis_patterns
    }
  rescue => e
    Rails.logger.error "Error gathering cable stats: #{e.message}"
    {
      total_connections: 0,
      worker_pool_size: 0,
      redis_connected: false,
      uptime: 0,
      active_subscriptions: 0,
      redis_patterns_found: {}
    }
  end
  
  def gather_connection_info
    return [] unless ActionCable.server.respond_to?(:connections)
    
    ActionCable.server.connections.map do |conn|
      {
        user: conn.respond_to?(:current_user) ? conn.current_user : nil,
        connection_identifier: conn.respond_to?(:connection_identifier) ? conn.connection_identifier : 'unknown',
        started_at: conn.respond_to?(:started_at) ? conn.started_at : Time.current,
        subscriptions: extract_connection_subscriptions(conn)
      }
    end
  rescue => e
    Rails.logger.error "Error gathering connections: #{e.message}"
    []
  end
  
  def gather_subscription_info
    detailed = gather_detailed_subscriptions
    detailed[:by_channel] || {}
  rescue => e
    Rails.logger.error "Error gathering subscriptions: #{e.message}"
    {}
  end
  
  def gather_detailed_subscriptions
    return default_subscription_response unless ActionCable.server.respond_to?(:pubsub)
    
    redis = ActionCable.server.pubsub.redis_connection_for_subscriptions
    
    # Try multiple Redis key patterns that ActionCable might use
    patterns_to_check = [
      '_action_cable_internal:*',
      'action_cable:*',
      'action_cable/*'
    ]
    
    all_keys = []
    patterns_checked = {}
    
    patterns_to_check.each do |pattern|
      keys = redis.keys(pattern)
      patterns_checked[pattern] = keys.count
      all_keys.concat(keys)
    end
    
    # Also check Redis PUBSUB channels (the actual subscription mechanism)
    pubsub_channels = redis.pubsub('channels', '*')
    
    # Group subscriptions by channel
    by_channel = {}
    by_user = {}
    
    # Process connection-based subscriptions
    ActionCable.server.connections.each do |conn|
      user_id = conn.current_user&.id
      subscriptions = extract_connection_subscriptions(conn)
      
      subscriptions.each do |channel_name|
        by_channel[channel_name] ||= 0
        by_channel[channel_name] += 1
        
        if user_id
          by_user[user_id] ||= []
          by_user[user_id] << channel_name unless by_user[user_id].include?(channel_name)
        end
      end
    end
    
    # Include PUBSUB channels as potential subscriptions
    pubsub_channels.each do |channel|
      by_channel[channel] ||= 0
      by_channel[channel] += 1
    end
    
    {
      total: by_channel.values.sum,
      by_channel: by_channel,
      by_user: by_user,
      all_channels: by_channel.keys,
      patterns_checked: patterns_checked,
      pubsub_channels_count: pubsub_channels.count
    }
  rescue => e
    Rails.logger.error "Error gathering detailed subscriptions: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    default_subscription_response
  end
  
  def extract_connection_subscriptions(connection)
    subscriptions = []
    
    # Try to access the connection's subscriptions
    # ActionCable stores subscriptions in the connection's @subscriptions instance variable
    if connection.instance_variable_defined?(:@subscriptions)
      subs = connection.instance_variable_get(:@subscriptions)
      
      if subs.respond_to?(:identifiers)
        subscriptions = subs.identifiers.map do |identifier|
          begin
            JSON.parse(identifier)['channel'] rescue identifier
          rescue
            identifier
          end
        end
      elsif subs.respond_to?(:keys)
        subscriptions = subs.keys.map do |key|
          begin
            JSON.parse(key)['channel'] rescue key
          rescue
            key
          end
        end
      end
    end
    
    # Fallback: try to extract from streams
    if subscriptions.empty? && connection.respond_to?(:streams)
      subscriptions = connection.streams.to_a
    end
    
    subscriptions
  rescue => e
    Rails.logger.error "Error extracting subscriptions from connection: #{e.message}"
    []
  end
  
  def count_active_subscriptions
    ActionCable.server.connections.sum do |conn|
      extract_connection_subscriptions(conn).count
    end
  rescue => e
    Rails.logger.error "Error counting active subscriptions: #{e.message}"
    0
  end
  
  def count_redis_patterns
    return {} unless ActionCable.server.respond_to?(:pubsub)
    
    redis = ActionCable.server.pubsub.redis_connection_for_subscriptions
    
    patterns = {
      'action_cable/*' => 0,
      '_action_cable_internal:*' => 0,
      'action_cable:*' => 0
    }
    
    patterns.each do |pattern, _|
      patterns[pattern] = redis.keys(pattern).count
    end
    
    # Add PUBSUB channels count
    patterns['pubsub_channels'] = redis.pubsub('channels', '*').count
    
    patterns
  rescue => e
    Rails.logger.error "Error counting Redis patterns: #{e.message}"
    {}
  end
  
  def default_subscription_response
    {
      total: 0,
      by_channel: {},
      by_user: {},
      all_channels: [],
      patterns_checked: {},
      pubsub_channels_count: 0
    }
  end
  
  def safe_connection_count
    return 0 unless ActionCable.server.respond_to?(:connections)
    ActionCable.server.connections.size
  rescue => e
    Rails.logger.error "Error getting connection count: #{e.message}"
    0
  end
  
  def safe_worker_pool_size
    # ActionCable's worker pool size is configured, not runtime accessible
    # Return the configured value from cable.yml or default
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
    # ActionCable doesn't track started_at by default
    # You would need to add this tracking yourself or use process start time
    0
  rescue
    0
  end
end