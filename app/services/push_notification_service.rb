# app/services/push_notification_service.rb
class PushNotificationService
  require 'net/http'
  require 'json'
  
  EXPO_PUSH_URL = 'https://exp.host/--/api/v2/push/send'
  BATCH_SIZE = 100
  
  def initialize
    @failed_tokens = []
  end
  
  # Send immediate push notification (for real-time experience)
  def send_immediate(notification)
    return unless notification.user.push_tokens.active.any?
    
    Rails.logger.info "📱 Sending immediate push for notification #{notification.id}"
    
    tokens = notification.user.push_tokens.active.expo_tokens.pluck(:token)
    return if tokens.empty?
    
    messages = build_push_messages(notification, tokens)
    send_to_expo(messages)
    
    notification.mark_as_delivered!
    cleanup_failed_tokens
    
  rescue => e
    Rails.logger.error "❌ Immediate push failed for notification #{notification.id}: #{e.message}"
    notification.mark_as_failed!
  end
  
  # Batch send for multiple notifications
  def send_batch(notifications)
    expo_messages = []
    
    notifications.each do |notification|
      tokens = notification.user.push_tokens.active.expo_tokens.pluck(:token)
      next if tokens.empty?
      
      messages = build_push_messages(notification, tokens)
      expo_messages.concat(messages)
      
      # Process in batches to avoid overwhelming the service
      if expo_messages.size >= BATCH_SIZE
        send_to_expo(expo_messages)
        expo_messages = []
      end
    end
    
    # Send remaining messages
    send_to_expo(expo_messages) if expo_messages.any?
    cleanup_failed_tokens
  end
  
  private
  
  def build_push_messages(notification, tokens)
    tokens.map do |token|
      {
        to: token,
        title: notification.title,
        body: notification.message,
        data: build_notification_data(notification),
        sound: determine_sound(notification),
        badge: notification.user.notifications.unread.count,
        priority: determine_priority(notification),
        categoryId: determine_category(notification),
        channelId: 'default'
      }
    end
  end
  
  def build_notification_data(notification)
    data = {
      notification_id: notification.id.to_s,
      type: notification.notification_type,
      created_at: notification.created_at.iso8601
    }
    
    # Add specific data based on notification type
    case notification.notification_type
    when 'package_update', 'package_delivered', 'package_ready'
      if notification.package
        data.merge!({
          package_id: notification.package.id.to_s,
          package_code: notification.package.code
        })
      end
    when 'payment_reminder', 'payment_failed'
      data[:action_url] = notification.action_url if notification.action_url
    end
    
    data
  end
  
  def determine_sound(notification)
    case notification.priority.to_s
    when 'urgent'
      'notification_urgent.wav'
    when 'high'
      'notification_high.wav'
    else
      'default'
    end
  end
  
  def determine_priority(notification)
    case notification.priority.to_s
    when 'urgent'
      'high'
    when 'high'
      'normal'
    else
      'default'
    end
  end
  
  def determine_category(notification)
    case notification.notification_type
    when 'package_update', 'package_delivered', 'package_ready'
      'package_update'
    else
      'general'
    end
  end
  
  def send_to_expo(messages)
    return if messages.empty?
    
    uri = URI(EXPO_PUSH_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    
    request = Net::HTTP::Post.new(uri)
    request['Accept'] = 'application/json'
    request['Content-Type'] = 'application/json'
    request.body = messages.to_json
    
    Rails.logger.info "📱 Sending #{messages.size} push notifications to Expo"
    
    response = http.request(request)
    
    if response.code == '200'
      response_data = JSON.parse(response.body)
      handle_expo_response(response_data, messages)
      Rails.logger.info "✅ Push notifications sent successfully"
    else
      Rails.logger.error "❌ Expo push failed: #{response.code} - #{response.body}"
      raise "Expo push service error: #{response.code}"
    end
    
  rescue Net::TimeoutError => e
    Rails.logger.error "❌ Push notification timeout: #{e.message}"
    raise e
  rescue => e
    Rails.logger.error "❌ Push notification error: #{e.message}"
    raise e
  end
  
  def handle_expo_response(response_data, messages)
    return unless response_data['data']
    
    response_data['data'].each_with_index do |result, index|
      next unless result['status'] == 'error'
      
      token = messages[index]['to']
      error_type = result['details']['error']
      
      case error_type
      when 'DeviceNotRegistered', 'InvalidCredentials'
        @failed_tokens << token
        Rails.logger.warn "🔄 Marking token as failed: #{token} - #{error_type}"
      else
        Rails.logger.warn "⚠️ Push error for token #{token}: #{error_type}"
      end
    end
  end
  
  def cleanup_failed_tokens
    return if @failed_tokens.empty?
    
    PushToken.where(token: @failed_tokens).find_each(&:mark_as_failed!)
    Rails.logger.info "🧹 Cleaned up #{@failed_tokens.size} failed tokens"
    @failed_tokens = []
  end
end