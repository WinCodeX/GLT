# app/controllers/api/v1/mpesa_controller.rb
module Api
  module V1
    class MpesaController < ApplicationController
      before_action :authenticate_user!, except: [:callback, :timeout, :b2c_callback, :verify_callback, :verify_timeout]
      
      before_action :force_json_format

      # POST /api/v1/mpesa/stk_push - Single package payment
      def stk_push
        begin
          package_id = params[:package_id]
          phone_number = params[:phone_number]
          amount = params[:amount]&.to_f

          # Validate inputs
          unless package_id.present? && phone_number.present? && amount && amount > 0
            return render json: {
              status: 'error',
              message: 'Missing required parameters: package_id, phone_number, or amount'
            }, status: :unprocessable_entity
          end

          # Find package
          package = current_user.packages.find_by(id: package_id)
          unless package
            return render json: {
              status: 'error',
              message: 'Package not found or access denied'
            }, status: :not_found
          end

          # Check if already paid
          if package.state != 'pending_unpaid'
            return render json: {
              status: 'error',
              message: 'Package has already been paid for'
            }, status: :unprocessable_entity
          end

          # Format phone number
          formatted_phone = MpesaService.format_phone_number(phone_number)
          unless MpesaService.validate_phone_number(formatted_phone)
            return render json: {
              status: 'error',
              message: 'Invalid phone number format'
            }, status: :unprocessable_entity
          end

          Rails.logger.info "Initiating STK push for package #{package.code}"

          # Initiate STK push
          result = MpesaService.initiate_stk_push(
            phone_number: formatted_phone,
            amount: amount,
            account_reference: package.code,
            transaction_desc: "Payment for package #{package.code}"
          )

          if result[:success]
            # Store payment request details
            package.update_columns(
              payment_request_id: result[:data]['CheckoutRequestID'],
              payment_merchant_request_id: result[:data]['MerchantRequestID'],
              payment_initiated_at: Time.current
            )

            render json: {
              status: 'success',
              message: 'STK push sent successfully',
              data: {
                checkout_request_id: result[:data]['CheckoutRequestID'],
                merchant_request_id: result[:data]['MerchantRequestID'],
                customer_message: result[:data]['CustomerMessage']
              }
            }
          else
            render json: {
              status: 'error',
              message: result[:message]
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "STK push error: #{e.message}"
          render json: {
            status: 'error',
            message: 'Failed to initiate payment'
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/mpesa/stk_push_bulk - Multiple packages payment
      def stk_push_bulk
        begin
          package_ids = params[:package_ids]
          phone_number = params[:phone_number]
          amount = params[:amount]&.to_f

          unless package_ids.is_a?(Array) && package_ids.any? && phone_number.present? && amount && amount > 0
            return render json: {
              status: 'error',
              message: 'Missing required parameters'
            }, status: :unprocessable_entity
          end

          # Find packages
          packages = current_user.packages.where(id: package_ids, state: 'pending_unpaid')
          
          unless packages.count == package_ids.count
            return render json: {
              status: 'error',
              message: 'Some packages not found or already paid'
            }, status: :not_found
          end

          # Validate total amount
          expected_total = packages.sum(:cost)
          if (amount - expected_total).abs > 1 # Allow 1 KES difference for rounding
            return render json: {
              status: 'error',
              message: "Amount mismatch. Expected: #{expected_total}, Got: #{amount}"
            }, status: :unprocessable_entity
          end

          formatted_phone = MpesaService.format_phone_number(phone_number)
          unless MpesaService.validate_phone_number(formatted_phone)
            return render json: {
              status: 'error',
              message: 'Invalid phone number format'
            }, status: :unprocessable_entity
          end

          package_codes = packages.pluck(:code).join(', ')
          Rails.logger.info "Initiating bulk STK push for packages: #{package_codes}"

          # Initiate STK push
          result = MpesaService.initiate_stk_push(
            phone_number: formatted_phone,
            amount: amount,
            account_reference: "BULK-#{packages.first.code}",
            transaction_desc: "Payment for #{packages.count} packages"
          )

          if result[:success]
            # Store payment request details for all packages
            packages.update_all(
              payment_request_id: result[:data]['CheckoutRequestID'],
              payment_merchant_request_id: result[:data]['MerchantRequestID'],
              payment_initiated_at: Time.current
            )

            render json: {
              status: 'success',
              message: 'STK push sent successfully',
              data: {
                checkout_request_id: result[:data]['CheckoutRequestID'],
                merchant_request_id: result[:data]['MerchantRequestID'],
                customer_message: result[:data]['CustomerMessage'],
                package_count: packages.count
              }
            }
          else
            render json: {
              status: 'error',
              message: result[:message]
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "Bulk STK push error: #{e.message}"
          render json: {
            status: 'error',
            message: 'Failed to initiate payment'
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/mpesa/query_status
      def query_status
        begin
          checkout_request_id = params[:checkout_request_id]

          unless checkout_request_id.present?
            return render json: {
              status: 'error',
              message: 'checkout_request_id is required'
            }, status: :unprocessable_entity
          end

          # Query M-Pesa
          result = MpesaService.query_stk_status(checkout_request_id)

          if result[:success]
            response_data = result[:data]
            result_code = response_data['ResultCode'].to_i

            transaction_status = case result_code
                                when 0 then 'completed'
                                when 1032 then 'cancelled'
                                when 1037 then 'timeout'
                                else 'pending'
                                end

            render json: {
              status: 'success',
              data: {
                transaction_status: transaction_status,
                result_code: result_code,
                result_desc: response_data['ResultDesc']
              }
            }
          else
            render json: {
              status: 'error',
              message: result[:message]
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "Query status error: #{e.message}"
          render json: {
            status: 'error',
            message: 'Failed to query payment status'
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/mpesa/verify_manual - Manual verification for single package
      def verify_manual
        begin
          transaction_code = params[:transaction_code]
          package_id = params[:package_id]
          amount = params[:amount]&.to_f

          unless transaction_code.present? && package_id.present? && amount
            return render json: {
              status: 'error',
              message: 'Missing required parameters'
            }, status: :unprocessable_entity
          end

          # Find package
          package = current_user.packages.find_by(id: package_id)
          unless package
            return render json: {
              status: 'error',
              message: 'Package not found or access denied'
            }, status: :not_found
          end

          # Check if already paid
          if package.state != 'pending_unpaid'
            return render json: {
              status: 'error',
              message: 'Package has already been paid for'
            }, status: :unprocessable_entity
          end

          Rails.logger.info "Manual verification for package #{package.code} with transaction: #{transaction_code}"

          # Use simplified verification for sandbox/development
          result = MpesaService.verify_transaction_simple(
            transaction_code: transaction_code,
            amount: amount,
            phone_number: current_user.phone_number
          )

          if result[:success]
            # Update package
            package.update!(
              state: 'pending',
              mpesa_receipt_number: transaction_code.upcase,
              payment_completed_at: Time.current,
              payment_method: 'manual_verification',
              payment_metadata: result[:data]
            )

            render json: {
              status: 'success',
              message: 'Payment verified successfully',
              data: {
                package_code: package.code,
                transaction_code: transaction_code.upcase,
                verified: true
              }
            }
          else
            render json: {
              status: 'error',
              message: result[:message]
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "Manual verification error: #{e.message}"
          render json: {
            status: 'error',
            message: 'Verification failed'
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/mpesa/verify_manual_bulk - Manual verification for multiple packages
      def verify_manual_bulk
        begin
          transaction_code = params[:transaction_code]
          package_ids = params[:package_ids]
          amount = params[:amount]&.to_f

          unless transaction_code.present? && package_ids.is_a?(Array) && package_ids.any? && amount
            return render json: {
              status: 'error',
              message: 'Missing required parameters'
            }, status: :unprocessable_entity
          end

          # Find packages
          packages = current_user.packages.where(id: package_ids, state: 'pending_unpaid')
          
          unless packages.count == package_ids.count
            return render json: {
              status: 'error',
              message: 'Some packages not found or already paid'
            }, status: :not_found
          end

          # Validate total amount
          expected_total = packages.sum(:cost)
          if (amount - expected_total).abs > 1
            return render json: {
              status: 'error',
              message: "Amount mismatch. Expected: #{expected_total}, Got: #{amount}"
            }, status: :unprocessable_entity
          end

          package_codes = packages.pluck(:code).join(', ')
          Rails.logger.info "Bulk manual verification for packages: #{package_codes} with transaction: #{transaction_code}"

          # Verify transaction
          result = MpesaService.verify_transaction_simple(
            transaction_code: transaction_code,
            amount: amount,
            phone_number: current_user.phone_number
          )

          if result[:success]
            # Update all packages
            packages.update_all(
              state: 'pending',
              mpesa_receipt_number: transaction_code.upcase,
              payment_completed_at: Time.current,
              payment_method: 'manual_verification_bulk'
            )

            render json: {
              status: 'success',
              message: 'Payments verified successfully',
              data: {
                package_codes: packages.pluck(:code),
                transaction_code: transaction_code.upcase,
                verified: true,
                package_count: packages.count
              }
            }
          else
            render json: {
              status: 'error',
              message: result[:message]
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "Bulk manual verification error: #{e.message}"
          render json: {
            status: 'error',
            message: 'Verification failed'
          }, status: :internal_server_error
        end
      end

      # POST /mpesa/callback - M-Pesa STK Push callback
      def callback
        begin
          Rails.logger.info "M-Pesa callback received: #{params.to_json}"

          callback_data = params.to_unsafe_h
          result = MpesaService.process_stk_callback(callback_data)

          if result[:success]
            # Find package(s) by checkout_request_id
            packages = Package.where(payment_request_id: result[:checkout_request_id])

            if packages.any?
              packages.each do |package|
                package.update!(
                  state: 'pending',
                  mpesa_receipt_number: result[:mpesa_receipt_number],
                  payment_completed_at: Time.current,
                  payment_metadata: result
                )

                Rails.logger.info "Package #{package.code} payment completed via M-Pesa"
              end
            else
              Rails.logger.warn "No packages found for checkout_request_id: #{result[:checkout_request_id]}"
            end
          else
            Rails.logger.warn "Payment failed: #{result[:result_desc]}"
            
            # Update packages to show payment failed
            packages = Package.where(payment_request_id: result[:checkout_request_id])
            packages.update_all(
              payment_failed_at: Time.current,
              payment_failure_reason: result[:result_desc]
            )
          end

          # Always return success to M-Pesa
          render json: {
            ResultCode: 0,
            ResultDesc: 'Success'
          }

        rescue => e
          Rails.logger.error "Callback processing error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          # Still return success to M-Pesa to avoid retries
          render json: {
            ResultCode: 0,
            ResultDesc: 'Success'
          }
        end
      end

      # POST /mpesa/timeout - M-Pesa timeout callback
      def timeout
        begin
          Rails.logger.info "M-Pesa timeout received: #{params.to_json}"
          
          # Mark payment as timeout
          checkout_request_id = params.dig(:Body, :stkCallback, :CheckoutRequestID)
          if checkout_request_id
            packages = Package.where(payment_request_id: checkout_request_id)
            packages.update_all(
              payment_failed_at: Time.current,
              payment_failure_reason: 'Payment request timeout'
            )
          end

          render json: {
            ResultCode: 0,
            ResultDesc: 'Success'
          }

        rescue => e
          Rails.logger.error "Timeout processing error: #{e.message}"
          render json: {
            ResultCode: 0,
            ResultDesc: 'Success'
          }
        end
      end

      # POST /mpesa/b2c_callback - M-Pesa B2C callback (for withdrawals)
      def b2c_callback
        begin
          Rails.logger.info "M-Pesa B2C callback received: #{params.to_json}"

          callback_data = params.to_unsafe_h
          result = MpesaService.process_b2c_callback(callback_data)

          if result[:success]
            # Find withdrawal by originator_conversation_id
            withdrawal = Withdrawal.find_by(mpesa_request_id: result[:originator_conversation_id])

            if withdrawal
              withdrawal.mark_completed!(receipt_number: result[:transaction_receipt])
              Rails.logger.info "Withdrawal #{withdrawal.id} completed via B2C"
            else
              Rails.logger.warn "No withdrawal found for conversation_id: #{result[:originator_conversation_id]}"
            end
          else
            Rails.logger.warn "B2C payment failed: #{result[:result_desc]}"
            
            # Update withdrawal to failed
            withdrawal = Withdrawal.find_by(mpesa_request_id: result[:originator_conversation_id])
            withdrawal&.handle_failure!(result[:result_desc])
          end

          render json: {
            ResultCode: 0,
            ResultDesc: 'Success'
          }

        rescue => e
          Rails.logger.error "B2C callback processing error: #{e.message}"
          render json: {
            ResultCode: 0,
            ResultDesc: 'Success'
          }
        end
      end

      # POST /mpesa/verify_callback - Transaction verification callback
      def verify_callback
        begin
          Rails.logger.info "M-Pesa verification callback received: #{params.to_json}"
          
          # Process verification results if needed
          render json: {
            ResultCode: 0,
            ResultDesc: 'Success'
          }

        rescue => e
          Rails.logger.error "Verification callback error: #{e.message}"
          render json: {
            ResultCode: 0,
            ResultDesc: 'Success'
          }
        end
      end

      # POST /mpesa/verify_timeout
      def verify_timeout
        begin
          Rails.logger.info "M-Pesa verification timeout received: #{params.to_json}"
          
          render json: {
            ResultCode: 0,
            ResultDesc: 'Success'
          }

        rescue => e
          Rails.logger.error "Verification timeout error: #{e.message}"
          render json: {
            ResultCode: 0,
            ResultDesc: 'Success'
          }
        end
      end

      private

      def force_json_format
        request.format = :json
      end
    end
  end
end