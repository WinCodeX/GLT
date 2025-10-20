# app/services/africas_talking_service.rb
class AfricasTalkingService
  include HTTParty
  base_uri 'https://api.africastalking.com/version1'

  def initialize
    @username = ENV['AT_USERNAME']
    @api_key = ENV['AT_API_KEY']
    
    raise "AT_USERNAME not set" if @username.blank?
    raise "AT_API_KEY not set" if @api_key.blank?
    
    @options = {
      headers: {
        'Accept' => 'application/json',
        'Content-Type' => 'application/x-www-form-urlencoded',
        'apiKey' => @api_key
      }
    }
  end

  def send_sms(to:, message:, from: nil)
    body = {
      username: @username,
      to: to,
      message: message
    }
    body[:from] = from if from.present?

    response = self.class.post('/messaging', 
      body: body,
      headers: @options[:headers]
    )

    handle_response(response)
  end

  def send_bulk_sms(recipients:, message:, from: nil)
    to = recipients.is_a?(Array) ? recipients.join(',') : recipients
    send_sms(to: to, message: message, from: from)
  end

  private

  def handle_response(response)
    if response.success?
      parsed = JSON.parse(response.body)
      
      # Check if SMS was accepted
      if parsed['SMSMessageData'] && parsed['SMSMessageData']['Recipients']
        recipients = parsed['SMSMessageData']['Recipients']
        
        # Check if any recipient was successful
        successful = recipients.any? { |r| r['statusCode'] == 101 }
        
        if successful
          { 
            success: true, 
            data: parsed,
            message: "SMS sent successfully"
          }
        else
          { 
            error: true, 
            message: recipients.first['status'] || 'Failed to send SMS',
            data: parsed
          }
        end
      else
        parsed
      end
    else
      { 
        error: true, 
        message: response.message || "HTTP Error: #{response.code}",
        code: response.code 
      }
    end
  rescue JSON::ParserError => e
    { 
      error: true, 
      message: "Failed to parse response: #{e.message}",
      raw_response: response.body
    }
  end
end