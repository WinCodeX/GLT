# app/controllers/mpesa_controller.rb (web version)
class MpesaController < WebApplicationController
  # Web-based M-Pesa endpoints that use session authentication
  
  # POST /mpesa/stk_push
  def stk_push
    begin
      phone_number = normalize_phone_number(params[:phone_number])
      amount = params[:amount].to_f
      package_id = params[:package_id]
      
      # Validate parameters
      if phone_number.blank? || amount <= 0 || package_id.blank?
        return render json: {
          status: 'error',
          message: 'Invalid parameters provided',
          code: 'validation_error'
        }, status: :bad_request
      end

      # Find package to ensure it exists
      package = current_user.packages.find_by(id: package_id)
      unless package
        return render json: {
          status: 'error',
          message: 'Package not found',
          code: 'package_not_found'
        }, status: :not_found
      end

      # Check if package can be paid
      unless ['pending_unpaid', 'pending'].include?(package.state)
        return render json: {
          status: 'error',
          message: 'Package cannot be paid at this time',
          code: 'invalid_state'
        }, status: :unprocessable_entity
      end

      # Initiate STK push
      result = MpesaService.initiate_stk_push(
        phone_number: phone_number,
        amount: amount,
        account_reference: package.code,
        transaction_desc: "Payment for package #{package.code}"
      )

      if result[:success]
        # Store transaction reference
        MpesaTransaction.create!(
          checkout_request_id: result[:data][:CheckoutRequestID],
          merchant_request_id: result[:data][:MerchantRequestID],
          package_id: package.id,
          user_id: current_user.id,
          phone_number: phone_number,
          amount: amount,
          status: 'pending'
        )

        render json: {
          status: 'success',
          message: 'STK push initiated successfully. Please check your phone.',
          checkout_request_id: result[:data][:CheckoutRequestID],
          merchant_request_id: result[:data][:MerchantRequestID]
        }
      else
        render json: {
          status: 'error',
          message: result[:message] || 'Failed to initiate payment',
          code: 'stk_push_failed'
        }, status: :unprocessable_entity
      end

    rescue => e
      Rails.logger.error "Web M-Pesa STK Push error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      render json: {
        status: 'error',
        message: 'Payment initiation failed',
        code: 'internal_error',
        debug: Rails.env.development? ? e.message : nil
      }, status: :internal_server_error
    end
  end

  # POST /mpesa/query_status
  def query_status
    begin
      checkout_request_id = params[:checkout_request_id]
      
      unless checkout_request_id.present?
        return render json: {
          status: 'error',
          message: 'Checkout request ID required',
          code: 'validation_error'
        }, status: :bad_request
      end

      transaction = current_user.mpesa_transactions.find_by(checkout_request_id: checkout_request_id)

      unless transaction
        return render json: {
          status: 'error',
          message: 'Transaction not found',
          code: 'transaction_not_found'
        }, status: :not_found
      end

      # Query transaction status
      result = MpesaService.query_stk_status(checkout_request_id)

      if result[:success]
        # Update transaction status
        status = result[:data][:ResultCode] == '0' ? 'completed' : 'failed'
        transaction.update!(
          status: status,
          result_code: result[:data][:ResultCode],
          result_desc: result[:data][:ResultDesc]
        )

        # Update package status if payment successful
        if status == 'completed'
          package = transaction.package
          package.update!(state: 'pending') if package.state == 'pending_unpaid'
        end

        render json: {
          status: 'success',
          message: 'Transaction status retrieved successfully',
          status: status,
          result_code: result[:data][:ResultCode],
          result_desc: result[:data][:ResultDesc]
        }
      else
        render json: {
          status: 'error',
          message: result[:message] || 'Failed to query transaction status',
          code: 'query_failed'
        }, status: :unprocessable_entity
      end

    rescue => e
      Rails.logger.error "Web M-Pesa query error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      render json: {
        status: 'error',
        message: 'Failed to query transaction status',
        code: 'internal_error',
        debug: Rails.env.development? ? e.message : nil
      }, status: :internal_server_error
    end
  end

  private

  def normalize_phone_number(phone)
    return nil if phone.blank?
    
    # Remove any non-digit characters
    clean_phone = phone.gsub(/\D/, '')
    
    # Handle different formats
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
end