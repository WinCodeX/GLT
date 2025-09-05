# app/services/mpesa_service.rb
class MpesaService
  include HTTParty

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

  private

  def self.get_access_token
    begin
      # Cache access token for 55 minutes (expires in 1 hour)
      cache_key = "mpesa_access_token"
      cached_token = Rails.cache.read(cache_key)
      return cached_token if cached_token

      credentials = Base64.strict_encode64("#{consumer_key}:#{consumer_secret}")

      response = HTTParty.get(
        "#{BASE_URL}/oauth/v1/generate?grant_type=client_credentials",
        headers: {
          'Authorization' => "Basic #{credentials}",
          'Content-Type' => 'application/json'
        },
        timeout: 30
      )

      if response.success? && response.parsed_response['access_token']
        access_token = response.parsed_response['access_token']
        
        # Cache for 55 minutes
        Rails.cache.write(cache_key, access_token, expires_in: 55.minutes)
        
        access_token
      else
        Rails.logger.error "Failed to get access token: #{response.body}"
        nil
      end

    rescue => e
      Rails.logger.error "Access token error: #{e.message}"
      nil
    end
  end

  def self.consumer_key
    ENV.fetch('MPESA_CONSUMER_KEY') do
      raise 'MPESA_CONSUMER_KEY environment variable not set'
    end
  end

  def self.consumer_secret
    ENV.fetch('MPESA_CONSUMER_SECRET') do
      raise 'MPESA_CONSUMER_SECRET environment variable not set'
    end
  end

  def self.business_short_code
    ENV.fetch('MPESA_BUSINESS_SHORT_CODE') do
      raise 'MPESA_BUSINESS_SHORT_CODE environment variable not set'
    end
  end

  def self.passkey
    ENV.fetch('MPESA_PASSKEY') do
      raise 'MPESA_PASSKEY environment variable not set'
    end
  end
end