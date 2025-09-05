# app/controllers/api/v1/mpesa_controller.rb
module Api
  module V1
    class MpesaController < ApplicationController
      before_action :authenticate_user!, except: [:callback, :timeout]
      skip_before_action :verify_authenticity_token, only: [:callback, :timeout]

      # POST /api/v1/mpesa/stk_push
      def stk_push
        begin
          phone_number = normalize_phone_number(params[:phone_number])
          amount = params[:amount].to_f
          package_id = params[:package_id]
          
          # Validate parameters
          if phone_number.blank? || amount <= 0 || package_id.blank?
            return error_response('Invalid parameters provided', 'validation_error', :bad_request)
          end

          # Find package to ensure it exists
          package = Package.find_by(id: package_id, user: current_user)
          unless package
            return error_response('Package not found', 'package_not_found', :not_found)
          end

          # Check if package can be paid
          unless ['pending_unpaid', 'pending'].include?(package.state)
            return error_response('Package cannot be paid at this time', 'invalid_state', :unprocessable_entity)
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

            success_response(
              {
                checkout_request_id: result[:data][:CheckoutRequestID],
                merchant_request_id: result[:data][:MerchantRequestID]
              },
              'STK push initiated successfully. Please check your phone.'
            )
          else
            error_response(
              result[:message] || 'Failed to initiate payment',
              'stk_push_failed',
              :unprocessable_entity
            )
          end

        rescue => e
          Rails.logger.error "M-Pesa STK Push error: #{e.message}"
          error_response(
            'Payment initiation failed',
            'internal_error',
            :internal_server_error
          )
        end
      end

      # POST /api/v1/mpesa/query_status
      def query_status
        begin
          checkout_request_id = params[:checkout_request_id]
          
          unless checkout_request_id.present?
            return error_response('Checkout request ID required', 'validation_error', :bad_request)
          end

          transaction = MpesaTransaction.find_by(
            checkout_request_id: checkout_request_id,
            user_id: current_user.id
          )

          unless transaction
            return error_response('Transaction not found', 'transaction_not_found', :not_found)
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

            success_response(
              {
                status: status,
                result_code: result[:data][:ResultCode],
                result_desc: result[:data][:ResultDesc]
              },
              'Transaction status retrieved successfully'
            )
          else
            error_response(
              result[:message] || 'Failed to query transaction status',
              'query_failed',
              :unprocessable_entity
            )
          end

        rescue => e
          Rails.logger.error "M-Pesa query error: #{e.message}"
          error_response(
            'Failed to query transaction status',
            'internal_error',
            :internal_server_error
          )
        end
      end

      # POST /api/v1/mpesa/callback (from Safaricom)
      def callback
        begin
          Rails.logger.info "M-Pesa callback received: #{params.inspect}"

          # Extract callback data
          body = params[:Body] || params
          stk_callback = body[:stkCallback] || body[:STKCallback]

          unless stk_callback
            return render json: { ResultCode: 1, ResultDesc: 'Invalid callback format' }
          end

          checkout_request_id = stk_callback[:CheckoutRequestID]
          result_code = stk_callback[:ResultCode]
          result_desc = stk_callback[:ResultDesc]

          # Find transaction
          transaction = MpesaTransaction.find_by(checkout_request_id: checkout_request_id)

          if transaction
            # Update transaction
            if result_code == 0
              # Success - extract callback metadata
              callback_metadata = stk_callback[:CallbackMetadata]
              mpesa_receipt_number = nil
              phone_number = nil
              amount = nil

              if callback_metadata && callback_metadata[:Item]
                callback_metadata[:Item].each do |item|
                  case item[:Name]
                  when 'MpesaReceiptNumber'
                    mpesa_receipt_number = item[:Value]
                  when 'PhoneNumber'
                    phone_number = item[:Value]
                  when 'Amount'
                    amount = item[:Value]
                  end
                end
              end

              transaction.update!(
                status: 'completed',
                result_code: result_code,
                result_desc: result_desc,
                mpesa_receipt_number: mpesa_receipt_number,
                callback_phone_number: phone_number,
                callback_amount: amount
              )

              # Update package status
              package = transaction.package
              if package && package.state == 'pending_unpaid'
                package.update!(state: 'pending')
                Rails.logger.info "Package #{package.code} status updated to pending after successful payment"
              end

            else
              # Failed
              transaction.update!(
                status: 'failed',
                result_code: result_code,
                result_desc: result_desc
              )
            end

            Rails.logger.info "Transaction #{checkout_request_id} updated: #{transaction.status}"
          else
            Rails.logger.warn "Transaction not found for checkout_request_id: #{checkout_request_id}"
          end

          # Always respond with success to Safaricom
          render json: { ResultCode: 0, ResultDesc: 'Success' }

        rescue => e
          Rails.logger.error "M-Pesa callback error: #{e.message}"
          render json: { ResultCode: 1, ResultDesc: 'Internal error' }
        end
      end

      # POST /api/v1/mpesa/timeout (from Safaricom)
      def timeout
        begin
          Rails.logger.info "M-Pesa timeout received: #{params.inspect}"

          checkout_request_id = params[:CheckoutRequestID]
          
          if checkout_request_id
            transaction = MpesaTransaction.find_by(checkout_request_id: checkout_request_id)
            if transaction
              transaction.update!(
                status: 'timeout',
                result_desc: 'Transaction timeout'
              )
              Rails.logger.info "Transaction #{checkout_request_id} marked as timeout"
            end
          end

          render json: { ResultCode: 0, ResultDesc: 'Success' }

        rescue => e
          Rails.logger.error "M-Pesa timeout error: #{e.message}"
          render json: { ResultCode: 1, ResultDesc: 'Internal error' }
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
  end
end