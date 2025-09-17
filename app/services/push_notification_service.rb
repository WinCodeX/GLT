# app/services/push_notification_service.rb
class PushNotificationService
  require 'net/http'
  require 'json'
  require 'googleauth'
  
  # Use FCM v1 API (recommended) instead of legacy API
  FCM_V1_URL = 'https://fcm.googleapis.com/v1/projects/glt-logistics/messages:send'
  FCM_LEGACY_URL = 'https://fcm.googleapis.com/fcm/send'
  BATCH_SIZE = 500 # FCM supports up to 500 tokens per request
  
  def initialize
    @failed_tokens = []
  end
  
  # Send immediate push notification
  def send_immediate(notification)
    return unless notification.user.push_tokens.active.any?
    
    Rails.logger.info "📱 Sending immediate FCM push for notification #{notification.id}"
    
    # Get all active FCM tokens
    fcm_tokens = notification.user.push_tokens.active.where(platform: 'fcm').pluck(:token)
    return if fcm_tokens.empty?
    
    send_to_fcm(notification, fcm_tokens)
    
    notification.mark_as_delivered!
    cleanup_failed_tokens
    
  rescue => e
    Rails.logger.error "❌ Immediate FCM push failed for notification #{notification.id}: #{e.message}"
    notification.mark_as_failed!
  end
  
  # Batch send for multiple notifications
  def send_batch(notifications)
    notifications.each do |notification|
      fcm_tokens = notification.user.push_tokens.active.where(platform: 'fcm').pluck(:token)
      next if fcm_tokens.empty?
      
      send_to_fcm(notification, fcm_tokens)
    end
    
    cleanup_failed_tokens
  end
  
  private
  
  def send_to_fcm(notification, tokens)
    return if tokens.empty?
    
    Rails.logger.info "🔥 Sending #{tokens.size} FCM notifications"
    
    # Use multicast for multiple tokens (more efficient)
    if tokens.size > 1
      send_fcm_multicast(notification, tokens)
    else
      send_fcm_single(notification, tokens.first)
    end
    
  rescue => e
    Rails.logger.error "❌ FCM send error: #{e.message}"
    raise e
  end
  
  # Send to multiple tokens at once (FCM v1 multicast)
  def send_fcm_multicast(notification, tokens)
    # Split into batches of 500 (FCM limit)
    tokens.each_slice(BATCH_SIZE) do |token_batch|
      payload = {
        message: {
          tokens: token_batch,
          notification: build_fcm_notification(notification),
          data: build_notification_data(notification).transform_values(&:to_s),
          android: build_android_config(notification),
          apns: build_apns_config(notification)
        }
      }
      
      send_fcm_request(payload, token_batch)
    end
  end
  
  # Send to single token
  def send_fcm_single(notification, token)
    payload = {
      message: {
        token: token,
        notification: build_fcm_notification(notification),
        data: build_notification_data(notification).transform_values(&:to_s),
        android: build_android_config(notification),
        apns: build_apns_config(notification)
      }
    }
    
    send_fcm_request(payload, [token])
  end
  
  def send_fcm_request(payload, tokens)
    uri = URI(FCM_V1_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{get_access_token}"
    request['Content-Type'] = 'application/json'
    request.body = payload.to_json
    
    response = http.request(request)
    
    if response.code == '200'
      response_data = JSON.parse(response.body)
      handle_fcm_v1_response(response_data, tokens)
      Rails.logger.info "✅ FCM notifications sent successfully"
    else
      Rails.logger.error "❌ FCM push failed: #{response.code} - #{response.body}"
      
      # Mark tokens as potentially failed
      if response.code.to_i >= 400
        @failed_tokens.concat(tokens)
      end
      
      raise "FCM push service error: #{response.code}"
    end
    
  rescue Net::TimeoutError => e
    Rails.logger.error "❌ FCM timeout: #{e.message}"
    raise e
  rescue => e
    Rails.logger.error "❌ FCM request error: #{e.message}"
    raise e
  end
  
  def build_fcm_notification(notification)
    {
      title: notification.title,
      body: notification.message,
      image: notification.image_url # if you have images
    }
  end
  
  def build_android_config(notification)
    {
      notification: {
        icon: 'notification_icon',
        color: '#7c3aed',
        sound: determine_sound(notification),
        channel_id: determine_channel_id(notification),
        priority: determine_android_priority(notification),
        default_sound: determine_sound(notification) == 'default',
        default_vibrate_timings: true,
        default_light_settings: true
      },
      priority: 'high',
      ttl: '3600s' # 1 hour TTL
    }
  end
  
  def build_apns_config(notification)
    {
      payload: {
        aps: {
          alert: {
            title: notification.title,
            body: notification.message
          },
          sound: determine_sound(notification),
          badge: notification.user.notifications.unread.count,
          category: determine_category(notification),
          'content-available': 1,
          'mutable-content': 1
        }
      },
      headers: {
        'apns-priority': determine_apns_priority(notification),
        'apns-expiration': (Time.current + 1.hour).to_i.to_s
      }
    }
  end
  
  def build_notification_data(notification)
    data = {
      notification_id: notification.id.to_s,
      type: notification.notification_type,
      created_at: notification.created_at.iso8601
    }
    
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
  
  def determine_channel_id(notification)
    case notification.notification_type
    when 'package_update', 'package_delivered'
      'packages'
    when 'payment_reminder', 'payment_failed'
      'urgent'
    else
      'default'
    end
  end
  
  def determine_android_priority(notification)
    case notification.priority.to_s
    when 'urgent'
      'max'
    when 'high'
      'high'
    else
      'default'
    end
  end
  
  def determine_apns_priority(notification)
    case notification.priority.to_s
    when 'urgent'
      '10'
    else
      '5'
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
  
  def handle_fcm_v1_response(response_data, tokens)
    # Handle multicast response
    if response_data['responses']
      response_data['responses'].each_with_index do |result, index|
        next unless result['error']
        
        token = tokens[index]
        error_code = result['error']['code']
        error_message = result['error']['message']
        
        case error_code
        when 'UNREGISTERED', 'INVALID_ARGUMENT'
          @failed_tokens << token
          Rails.logger.warn "🔄 Marking FCM token as failed: #{token[0..20]}... - #{error_code}"
        else
          Rails.logger.warn "⚠️ FCM error for token #{token[0..20]}...: #{error_code} - #{error_message}"
        end
      end
    end
    
    # Handle single message response
    if response_data['error']
      error_code = response_data['error']['code']
      @failed_tokens.concat(tokens)
      Rails.logger.warn "🔄 Marking FCM tokens as failed: #{error_code}"
    end
  end
  
  def get_access_token
    # Use service account for FCM v1 API
    authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(service_account_json),
      scope: 'https://www.googleapis.com/auth/firebase.messaging'
    )
    
    authorizer.fetch_access_token!['access_token']
  rescue => e
    Rails.logger.error "❌ Failed to get FCM access token: #{e.message}"
    raise "FCM authentication failed"
  end
  
  def service_account_json
    # Try multiple sources for service account JSON
    json = Rails.application.credentials.firebase_service_account_json ||
           Rails.application.credentials.dig(:firebase, :service_account_json) ||
           ENV['FIREBASE_SERVICE_ACCOUNT_JSON']
    
    if json.nil?
      raise "Firebase service account JSON not configured"
    end
    
    # Handle both string and hash formats
    json.is_a?(String) ? json : json.to_json
  end
  
  def cleanup_failed_tokens
    return if @failed_tokens.empty?
    
    PushToken.where(token: @failed_tokens).find_each(&:mark_as_failed!)
    Rails.logger.info "🧹 Cleaned up #{@failed_tokens.size} failed FCM tokens"
    @failed_tokens = []
  end
end