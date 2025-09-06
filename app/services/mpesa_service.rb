# app/services/mpesa_service.rb
class MpesaService
  include HTTParty
  require 'net/http'
  require 'uri'
  require 'base64'
  require 'json'

  BASE_URL = Rails.env.production? ? 
    'https://api.safaricom.co.ke' : 
    'https://sandbox.safaricom.co.ke'

  def self.initiate_stk_push(phone_number:, amount:, account_reference:, transaction_desc:)
    begin
      access_token = get_access_token
      return { success: false, message: 'Failed to get access token' } unless access_token

      timestamp = Time.current.strftime('%Y%m%d%H%M%S')
      password = Base64.strict_encode64("#{business_short_code}#{passkey}#{timestamp}")

      payload = {
        BusinessShortCode: business_short_code,
        Password: password,
        Timestamp: timestamp,
        TransactionType: 'CustomerPayBillOnline',
        Amount: amount.to_i,
        PartyA: phone_number,
        PartyB: business_short_code,
        PhoneNumber: phone_number,
        CallBackURL: "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000')}/api/v1/mpesa/callback",
        AccountReference: account_reference,
        TransactionDesc: transaction_desc
      }

      response = HTTParty.post(
        "#{BASE_URL}/mpesa/stkpush/v1/processrequest",
        headers: {
          'Authorization' => "Bearer #{access_token}",
          'Content-Type' => 'application/json'
        },
        body: payload.to_json,
        timeout: 30
      )

      Rails.logger.info "STK Push response: #{response.body}"

      if response.success? && response.parsed_response['ResponseCode'] == '0'
        {
          success: true,
          data: response.parsed_response
        }
      else
        {
          success: false,
          message: response.parsed_response['errorMessage'] || response.parsed_response['ResponseDescription'] || 'STK push failed'
        }
      end

    rescue => e
      Rails.logger.error "STK Push error: #{e.message}"
      { success: false, message: 'Network error occurred' }
    end
  end

  def self.query_stk_status(checkout_request_id)
    begin
      access_token = get_access_token
      return { success: false, message: 'Failed to get access token' } unless access_token

      timestamp = Time.current.strftime('%Y%m%d%H%M%S')
      password = Base64.strict_encode64("#{business_short_code}#{passkey}#{timestamp}")

      payload = {
        BusinessShortCode: business_short_code,
        Password: password,
        Timestamp: timestamp,
        CheckoutRequestID: checkout_request_id
      }

      response = HTTParty.post(
        "#{BASE_URL}/mpesa/stkpushquery/v1/query",
        headers: {
          'Authorization' => "Bearer #{access_token}",
          'Content-Type' => 'application/json'
        },
        body: payload.to_json,
        timeout: 30
      )

      Rails.logger.info "STK Query response: #{response.body}"

      if response.success?
        {
          success: true,
          data: response.parsed_response
        }
      else
        {
          success: false,
          message: response.parsed_response['errorMessage'] || 'Query failed'
        }
      end

    rescue => e
      Rails.logger.error "STK Query error: #{e.message}"
      { success: false, message: 'Network error occurred' }
    end
  end

  # Debug method to test environment variables
  def self.test_environment
    Rails.logger.info "🔍 Testing M-Pesa Environment Variables:"
    Rails.logger.info "Rails Environment: #{Rails.env}"
    Rails.logger.info "All ENV keys: #{ENV.keys.count} total"
    Rails.logger.info "M-Pesa related ENV keys: #{ENV.keys.select { |k| k.include?('MPESA') }}"
    
    begin
      consumer_key
      consumer_secret  
      business_short_code
      passkey
      Rails.logger.info "✅ All M-Pesa environment variables loaded successfully"
      return true
    rescue => e
      Rails.logger.error "❌ Environment variable error: #{e.message}"
      return false
    end
  end

  private

  def self.get_access_token
    begin
      # Cache access token for 55 minutes (expires in 1 hour)
      cache_key = "mpesa_access_token"
      cached_token = Rails.cache.read(cache_key)
      return cached_token if cached_token

      # Debug: Log the credentials being used
      Rails.logger.info "Consumer Key: #{consumer_key}"
      Rails.logger.info "Consumer Secret: #{consumer_secret[0..5]}..." # Only log first 6 chars for security
      
      credentials = Base64.strict_encode64("#{consumer_key}:#{consumer_secret}")
      Rails.logger.info "Encoded credentials: #{credentials[0..20]}..." # Only log first 20 chars

      # Use GET request to match working Postman request
      url = URI("#{BASE_URL}/oauth/v1/generate?grant_type=client_credentials")
      
      https = Net::HTTP.new(url.host, url.port)
      https.use_ssl = true
      
      # FIXED: Use GET request instead of POST to match working Postman
      request = Net::HTTP::Get.new(url)
      request["Authorization"] = "Basic #{credentials}"
      
      Rails.logger.info "Making GET request to: #{url}"
      Rails.logger.info "Authorization header: Basic #{credentials[0..20]}..."
      
      response = https.request(request)
      
      Rails.logger.info "Response code: #{response.code}"
      Rails.logger.info "Response body: #{response.body}"

      if response.code == '200'
        result = JSON.parse(response.body)
        access_token = result['access_token']
        
        if access_token
          # Cache for 55 minutes
          Rails.cache.write(cache_key, access_token, expires_in: 55.minutes)
          Rails.logger.info "Access token generated successfully"
          return access_token
        else
          Rails.logger.error "No access token in response: #{response.body}"
          return nil
        end
      else
        Rails.logger.error "Failed to get access token - Code: #{response.code}, Body: #{response.body}"
        return nil
      end

    rescue => e
      Rails.logger.error "Access token error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      nil
    end
  end

  def self.consumer_key
    key = ENV['MPESA_CONSUMER_KEY']
    Rails.logger.info "MPESA_CONSUMER_KEY present: #{key.present?}"
    Rails.logger.info "MPESA_CONSUMER_KEY value: #{key ? key[0..10] + '...' : 'nil'}"
    
    unless key.present?
      Rails.logger.error "❌ MPESA_CONSUMER_KEY not found in environment"
      Rails.logger.error "Available ENV keys with MPESA: #{ENV.keys.select { |k| k.include?('MPESA') }}"
      raise 'MPESA_CONSUMER_KEY environment variable not set'
    end
    key
  end

  def self.consumer_secret
    secret = ENV['MPESA_CONSUMER_SECRET']
    Rails.logger.info "MPESA_CONSUMER_SECRET present: #{secret.present?}"
    Rails.logger.info "MPESA_CONSUMER_SECRET value: #{secret ? secret[0..10] + '...' : 'nil'}"
    
    unless secret.present?
      Rails.logger.error "❌ MPESA_CONSUMER_SECRET not found in environment"
      raise 'MPESA_CONSUMER_SECRET environment variable not set'
    end
    secret
  end

  def self.business_short_code
    code = ENV['MPESA_BUSINESS_SHORT_CODE']
    Rails.logger.info "MPESA_BUSINESS_SHORT_CODE: #{code}"
    
    unless code.present?
      Rails.logger.error "❌ MPESA_BUSINESS_SHORT_CODE not found in environment"
      raise 'MPESA_BUSINESS_SHORT_CODE environment variable not set'
    end
    code
  end

  def self.passkey
    key = ENV['MPESA_PASSKEY']
    Rails.logger.info "MPESA_PASSKEY present: #{key.present?}"
    Rails.logger.info "MPESA_PASSKEY value: #{key ? key[0..10] + '...' : 'nil'}"
    
    unless key.present?
      Rails.logger.error "❌ MPESA_PASSKEY not found in environment"
      raise 'MPESA_PASSKEY environment variable not set'
    end
    key
  end
end