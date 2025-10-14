# app/controllers/public/mpesa_controller.rb
module Public
  class MpesaController < WebApplicationController
    skip_before_action :authenticate_user!, only: [:initiate_payment, :check_payment_status, :callback]
    skip_before_action :verify_authenticity_token, only: [:initiate_payment, :check_payment_status, :callback]
    
    # POST /public/mpesa/initiate_payment
    def initiate_payment
      begin
        phone_number = normalize_phone_number(params[:phone_number])
        amount = params[:amount].to_f
        sender_phone = params[:sender_phone] # We'll use this to generate account reference
        
        Rails.logger.info "=" * 60
        Rails.logger.info "📦 PUBLIC PACKAGE PAYMENT INITIATION"
        Rails.logger.info "=" * 60
        Rails.logger.info "Phone: #{phone_number}"
        Rails.logger.info "Amount: #{amount}"
        Rails.logger.info "Sender Phone: #{sender_phone}"
        
        if phone_number.blank? || amount <= 0
          return render json: {
            success: false,
            message: 'Invalid payment parameters',
            error: 'validation_error'
          }, status: :bad_request
        end
        
        # Validate phone number format (must be 254XXXXXXXXX)
        unless phone_number.match?(/^254\d{9}$/)
          Rails.logger.error "❌ Invalid phone format: #{phone_number}"
          return render json: {
            success: false,
            message: "Invalid phone number format. Must be 254XXXXXXXXX (got: #{phone_number})",
            error: 'invalid_phone_format'
          }, status: :bad_request
        end
        
        # Validate amount range
        if amount < 1 || amount > 150000
          return render json: {
            success: false,
            message: 'Amount must be between KES 1 and KES 150,000',
            error: 'invalid_amount'
          }, status: :bad_request
        end
        
        # Generate simple account reference: GLT-{first 5 digits of sender phone}
        account_reference = generate_account_reference(sender_phone)
        
        Rails.logger.info "🔖 Account Reference: #{account_reference} (length: #{account_reference.length})"
        
        # Initiate STK push
        result = MpesaService.initiate_stk_push(
          phone_number: phone_number,
          amount: amount,
          account_reference: account_reference,
          transaction_desc: "Package payment",
          callback_url: "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000')}/public/mpesa/callback"
        )
        
        Rails.logger.info "📡 M-Pesa Response:"
        Rails.logger.info "Success: #{result[:success]}"
        
        if result[:data]
          Rails.logger.info "Data: #{result[:data].inspect}"
        end
        
        if result[:message]
          Rails.logger.error "❌ M-Pesa Error Message: #{result[:message]}"
        end
        
        if result[:error]
          Rails.logger.error "❌ M-Pesa Error Details: #{result[:error].inspect}"
        end
        
        if result[:response]
          Rails.logger.error "❌ Full M-Pesa Response: #{result[:response].inspect}"
        end
        
        if result[:success]
          # Store payment details in session
          session[:pending_package_payment] = {
            checkout_request_id: result[:data]['CheckoutRequestID'],
            merchant_request_id: result[:data]['MerchantRequestID'],
            phone_number: phone_number,
            amount: amount,
            account_reference: account_reference,
            initiated_at: Time.current.iso8601
          }
          
          Rails.logger.info "✅ Payment initiated successfully"
          Rails.logger.info "🎫 CheckoutRequestID: #{result[:data]['CheckoutRequestID']}"
          
          render json: {
            success: true,
            message: 'Payment initiated. Please check your phone.',
            checkout_request_id: result[:data]['CheckoutRequestID'],
            merchant_request_id: result[:data]['MerchantRequestID']
          }
        else
          Rails.logger.error "❌ M-Pesa STK Push failed: #{result[:message]}"
          
          # Get more detailed error info
          error_details = {
            message: result[:message] || 'Failed to initiate payment',
            error_code: result[:error_code],
            mpesa_response: result[:response]
          }
          
          Rails.logger.error "Full error details: #{error_details.inspect}"
          
          render json: {
            success: false,
            message: result[:message] || 'Failed to initiate payment',
            error: 'payment_initiation_failed',
            details: Rails.env.development? ? error_details : nil
          }, status: :unprocessable_entity
        end
        
      rescue => e
        Rails.logger.error "❌ PAYMENT INITIATION ERROR"
        Rails.logger.error "Error: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        
        render json: {
          success: false,
          message: 'Payment initiation failed',
          error: Rails.env.development? ? e.message : 'internal_error'
        }, status: :internal_server_error
      end
    end
    
    # GET /public/mpesa/check_payment_status
    def check_payment_status
      begin
        checkout_request_id = params[:checkout_request_id]
        
        unless checkout_request_id.present?
          return render json: {
            success: false,
            message: 'Checkout request ID required',
            error: 'validation_error'
          }, status: :bad_request
        end
        
        # Query M-Pesa
        result = MpesaService.query_stk_status(checkout_request_id)
        
        if result[:success]
          result_code = result[:data]['ResultCode'].to_i
          
          status = case result_code
                  when 0 then 'completed'
                  when 1032 then 'cancelled'
                  when 1037 then 'timeout'
                  else 'pending'
                  end
          
          render json: {
            success: true,
            payment_status: status,
            result_code: result_code,
            result_desc: result[:data]['ResultDesc'],
            can_proceed: status == 'completed'
          }
        else
          render json: {
            success: false,
            message: 'Failed to check payment status',
            error: 'status_check_failed'
          }, status: :unprocessable_entity
        end
        
      rescue => e
        Rails.logger.error "Payment status check error: #{e.message}"
        
        render json: {
          success: false,
          message: 'Failed to check payment status',
          error: Rails.env.development? ? e.message : 'internal_error'
        }, status: :internal_server_error
      end
    end
    
    # POST /public/mpesa/callback
    def callback
      begin
        raw_body = request.body.read
        request.body.rewind
        
        Rails.logger.info "=" * 60
        Rails.logger.info "💳 PUBLIC PACKAGE PAYMENT CALLBACK"
        Rails.logger.info "=" * 60
        Rails.logger.info "Raw Body: #{raw_body}"
        Rails.logger.info "=" * 60
        
        callback_data = JSON.parse(raw_body)
        stk_callback = callback_data.dig('Body', 'stkCallback')
        
        unless stk_callback
          Rails.logger.error "❌ Invalid callback structure"
          return render json: { ResultCode: 1, ResultDesc: 'Invalid callback structure' }
        end
        
        checkout_request_id = stk_callback['CheckoutRequestID']
        result_code = stk_callback['ResultCode'].to_i
        result_desc = stk_callback['ResultDesc']
        
        Rails.logger.info "🎫 CheckoutRequestID: #{checkout_request_id}"
        Rails.logger.info "📊 Result Code: #{result_code}"
        Rails.logger.info "📝 Result Description: #{result_desc}"
        
        if result_code == 0
          # Payment successful
          callback_metadata = stk_callback['CallbackMetadata']['Item']
          
          mpesa_receipt = extract_callback_value(callback_metadata, 'MpesaReceiptNumber')
          phone_number = extract_callback_value(callback_metadata, 'PhoneNumber')
          transaction_amount = extract_callback_value(callback_metadata, 'Amount')
          
          Rails.logger.info "✅ Payment Successful"
          Rails.logger.info "🧾 M-Pesa Receipt: #{mpesa_receipt}"
          Rails.logger.info "📞 Phone: #{phone_number}"
          Rails.logger.info "💵 Amount: #{transaction_amount}"
          
          # Store successful payment data in session for package creation
          # Note: Session data might not persist through callback, but we log it
          Rails.logger.info "Payment verified for checkout_request_id: #{checkout_request_id}"
        else
          Rails.logger.warn "❌ Payment failed"
          Rails.logger.warn "Reason: #{result_desc}"
        end
        
        render json: { ResultCode: 0, ResultDesc: 'Accepted' }
        
      rescue JSON::ParserError => e
        Rails.logger.error "❌ JSON Parse Error: #{e.message}"
        render json: { ResultCode: 0, ResultDesc: 'Accepted' }
      rescue => e
        Rails.logger.error "❌ CALLBACK ERROR"
        Rails.logger.error "Error: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { ResultCode: 0, ResultDesc: 'Accepted' }
      end
    end
    
    private
    
    def normalize_phone_number(phone)
      return nil if phone.blank?
      
      clean_phone = phone.gsub(/\D/, '')
      
      if clean_phone.start_with?('254')
        clean_phone
      elsif clean_phone.start_with?('0')
        "254#{clean_phone[1..-1]}"
      elsif clean_phone.length == 9
        "254#{clean_phone}"
      else
        clean_phone
      end
    end
    
    # Generate account reference: GLT{first 5 digits of phone}
    # NO HYPHENS - M-Pesa only accepts alphanumeric
    # Examples: GLT71229, GLT72234, GLT11122
    def generate_account_reference(phone)
      clean_phone = phone.to_s.gsub(/\D/, '')
      
      # Get first 5 digits
      # If phone starts with 254, take digits after 254
      # If phone starts with 0, take digits after 0
      # Otherwise take first 5 digits
      digits = if clean_phone.start_with?('254')
        clean_phone[3..7]
      elsif clean_phone.start_with?('0')
        clean_phone[1..5]
      else
        clean_phone[0..4]
      end
      
      # Ensure we have exactly 5 digits, pad with 0s if needed
      digits = digits.to_s.ljust(5, '0')[0..4]
      
      # NO HYPHEN - M-Pesa rejects special characters
      reference = "GLT#{digits}"
      
      # Max length check (should be 8 chars: GLT12345)
      reference[0..11] # Trim to 12 chars max just in case
    end
    
    def extract_callback_value(callback_items, key)
      return nil unless callback_items.is_a?(Array)
      
      item = callback_items.find { |i| i['Name'] == key }
      item&.dig('Value')
    end
  end
end