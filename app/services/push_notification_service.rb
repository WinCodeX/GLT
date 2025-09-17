# app/services/push_notification_service.rb
class PushNotificationService
  require 'net/http'
  require 'net/https'
  require 'json'
  require 'googleauth'
  require 'timeout'
  
  # Use FCM v1 API (recommended) instead of legacy API
  FCM_V1_URL = 'https://fcm.googleapis.com/v1/projects/glt-logistics/messages:send'
  BATCH_SIZE = 500 # FCM supports up to 500 tokens per request
  
  def initialize
    @failed_tokens = []
  end
  
  # Send immediate push notification
  def send_immediate(notification)
    return unless notification.user&.push_tokens&.active&.any?
    
    Rails.logger.info "Sending immediate FCM push for notification #{notification.id}"
    
    # Get all active FCM tokens - remove platform filter if column doesn't exist
    fcm_tokens = if notification.user.push_tokens.column_names.include?('platform')
      notification.user.push_tokens.active.where(platform: 'fcm').pluck(:token)
    else
      notification.user.push_tokens.active.pluck(:token)
    end
    
    return if fcm_tokens.empty?
    
    send_to_fcm(notification, fcm_tokens)
    
    # Update notification status safely
    update_notification_status(notification, 'delivered')
    cleanup_failed_tokens
    
  rescue => e
    Rails.logger.error "Immediate FCM push failed for notification #{notification.id}: #{e.message}"
    Rails.logger.error "Error details: #{e.class.name} - #{e.backtrace.first(3).join(', ')}"
    update_notification_status(notification, 'failed')
  end
  
  # Batch send for multiple notifications
  def send_batch(notifications)
    notifications.each do |notification|
      next unless notification.user&.push_tokens&.active&.any?
      
      fcm_tokens = if notification.user.push_tokens.column_names.include?('platform')
        notification.user.push_tokens.active.where(platform: 'fcm').pluck(:token)
      else
        notification.user.push_tokens.active.pluck(:token)
      end
      
      next if fcm_tokens.empty?
      
      send_to_fcm(notification, fcm_tokens)
    end
    
    cleanup_failed_tokens
  end
  
  private
  
  def send_to_fcm(notification, tokens)
    return if tokens.empty?
    
    Rails.logger.info "Sending #{tokens.size} FCM notifications"
    
    # Use multicast for multiple tokens (more efficient)
    if tokens.size > 1
      send_fcm_multicast(notification, tokens)
    else
      send_fcm_single(notification, tokens.first)
    end
    
  rescue => e
    Rails.logger.error "FCM send error: #{e.message}"
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
    http.open_timeout = 30
    
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{get_access_token}"
    request['Content-Type'] = 'application/json'
    request.body = payload.to_json
    
    response = nil
    
    # Use Timeout module instead of Net::TimeoutError
    Timeout::timeout(30) do
      response = http.request(request)
    end
    
    if response.code == '200'
      response_data = JSON.parse(response.body)
      handle_fcm_v1_response(response_data, tokens)
      Rails.logger.info "FCM notifications sent successfully"
    else
      Rails.logger.error "FCM push failed: #{response.code} - #{response.body}"
      
      # Mark tokens as potentially failed
      if response.code.to_i >= 400
        @failed_tokens.concat(tokens)
      end
      
      raise "FCM push service error: #{response.code}"
    end
    
  rescue Timeout::Error => e
    Rails.logger.error "FCM timeout: #{e.message}"
    raise e
  rescue => e
    Rails.logger.error "FCM request error: #{e.message}"
    raise e
  end
  
  def build_fcm_notification(notification)
    base_notification = {
      title: notification.title,
      body: notification.message
    }
    
    # Only add image if the method exists and returns a value
    if notification.respond_to?(:image_url) && notification.image_url.present?
      base_notification[:image] = notification.image_url
    end
    
    base_notification
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
    badge_count = if notification.user.respond_to?(:notifications)
      notification.user.notifications.where(read: false).count rescue 0
    else
      0
    end
    
    {
      payload: {
        aps: {
          alert: {
            title: notification.title,
            body: notification.message
          },
          sound: determine_sound(notification),
          badge: badge_count,
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
      if notification.respond_to?(:package) && notification.package
        data.merge!({
          package_id: notification.package.id.to_s,
          package_code: notification.package.code
        })
      end
    when 'payment_reminder', 'payment_failed'
      if notification.respond_to?(:action_url) && notification.action_url
        data[:action_url] = notification.action_url
      end
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
          Rails.logger.warn "Marking FCM token as failed: #{token[0..20]}... - #{error_code}"
        else
          Rails.logger.warn "FCM error for token #{token[0..20]}...: #{error_code} - #{error_message}"
        end
      end
    end
    
    # Handle single message response
    if response_data['error']
      error_code = response_data['error']['code']
      @failed_tokens.concat(tokens)
      Rails.logger.warn "Marking FCM tokens as failed: #{error_code}"
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
    Rails.logger.error "Failed to get FCM access token: #{e.message}"
    Rails.logger.error "Error class: #{e.class.name}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(3).join(', ')}"
    raise "FCM authentication failed: #{e.message}"
  end
  
  def service_account_json
    # FIXED: Access the correct credentials key based on your screenshot
    firebase_config = Rails.application.credentials.firebase_service_account_json
    
    if firebase_config.nil?
      Rails.logger.error "Firebase service account JSON not found in credentials"
      raise "Firebase service account JSON not configured in Rails credentials"
    end
    
    # The credential should already be a JSON string
    json_string = firebase_config.to_s.strip
    
    # Validate that we have valid JSON
    begin
      parsed = JSON.parse(json_string)
      
      # Check for required Firebase fields
      required_fields = %w[type project_id private_key client_email]
      missing_fields = required_fields.select { |field| parsed[field].blank? }
      
      if missing_fields.any?
        Rails.logger.error "Firebase credentials missing fields: #{missing_fields.join(', ')}"
        raise "Firebase credentials missing required fields: #{missing_fields.join(', ')}"
      end
      
      Rails.logger.info "Firebase service account JSON validated successfully"
      json_string
      
    rescue JSON::ParserError => e
      Rails.logger.error "Failed to parse Firebase service account JSON: #{e.message}"
      Rails.logger.error "JSON content preview: #{json_string[0..100]}..."
      raise "Firebase service account JSON is not valid JSON: #{e.message}"
    end
  rescue => e
    Rails.logger.error "Failed to get Firebase service account JSON: #{e.message}"
    raise "Firebase service account JSON not configured properly: #{e.message}"
  end
  
  def update_notification_status(notification, status)
    # Try different methods to update notification status
    case status
    when 'delivered'
      if notification.respond_to?(:mark_as_delivered!)
        notification.mark_as_delivered!
      elsif notification.respond_to?(:delivered=)
        notification.update(delivered: true, delivered_at: Time.current)
      elsif notification.respond_to?(:status=)
        notification.update(status: 'sent')
      else
        notification.update_column(:status, 'sent') if notification.respond_to?(:update_column)
      end
    when 'failed'
      if notification.respond_to?(:mark_as_failed!)
        notification.mark_as_failed!
      elsif notification.respond_to?(:status=)
        notification.update(status: 'failed')
      else
        notification.update_column(:status, 'failed') if notification.respond_to?(:update_column)
      end
    end
  rescue => e
    Rails.logger.error "Failed to update notification status: #{e.message}"
  end
  
  def cleanup_failed_tokens
    return if @failed_tokens.empty?
    
    # Try different methods to mark tokens as failed
    @failed_tokens.each do |token|
      push_token = PushToken.find_by(token: token)
      next unless push_token
      
      if push_token.respond_to?(:mark_as_failed!)
        push_token.mark_as_failed!
      elsif push_token.respond_to?(:active=)
        push_token.update(active: false)
      else
        Rails.logger.warn "Could not mark token as failed: #{token[0..20]}..."
      end
    end
    
    Rails.logger.info "Cleaned up #{@failed_tokens.size} failed FCM tokens"
    @failed_tokens = []
  rescue => e
    Rails.logger.error "Failed to cleanup tokens: #{e.message}"
    @failed_tokens = []
  end
end