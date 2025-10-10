# app/controllers/api/v1/mpesa_controller.rb
module Api
  module V1
    class MpesaController < ApplicationController
      before_action :authenticate_user!, except: [:callback, :timeout, :b2c_callback, :verify_callback, :verify_timeout, :wallet_callback]
      
      before_action :force_json_format

      # POST /api/v1/mpesa/topup - Wallet top-up (FIXED)
      def topup
        begin
          phone_number = params[:phone_number]
          amount = params[:amount]&.to_f

          # Validate inputs
          unless phone_number.present? && amount && amount > 0
            return render json: {
              status: 'error',
              message: 'Missing required parameters: phone_number or amount'
            }, status: :unprocessable_entity
          end

          # Validate amount limits
          if amount < 10
            return render json: {
              status: 'error',
              message: 'Minimum top-up amount is KES 10'
            }, status: :unprocessable_entity
          end

          if amount > 150000
            return render json: {
              status: 'error',
              message: 'Maximum top-up amount is KES 150,000'
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

          # Get or create wallet
          wallet = current_user.wallet || current_user.create_wallet

          unless wallet.client?
            return render json: {
              status: 'error',
              message: 'Only client wallets can be topped up directly'
            }, status: :forbidden
          end

          Rails.logger.info "Initiating wallet top-up for user #{current_user.id}, amount: #{amount}"

          # Use username or phone as account reference
          account_reference = current_user.username.presence || current_user.phone_number.gsub(/\D/, '')

          # Initiate STK push with explicit callback URL
          result = MpesaService.initiate_stk_push(
            phone_number: formatted_phone,
            amount: amount,
            account_reference: account_reference,
            transaction_desc: "Wallet top-up",
            callback_url: "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000')}/api/v1/mpesa/wallet_callback"
          )

          if result[:success]
            # FIXED: Store payment details in wallet metadata (like package payment stores in package columns)
            current_metadata = wallet.metadata || {}
            current_metadata['pending_topup'] = {
              checkout_request_id: result[:data]['CheckoutRequestID'],
              merchant_request_id: result[:data]['MerchantRequestID'],
              amount: amount,
              phone_number: formatted_phone,
              user_id: current_user.id,
              initiated_at: Time.current.iso8601
            }
            wallet.update_column(:metadata, current_metadata)

            Rails.logger.info "Wallet top-up initiated for wallet #{wallet.id} - CheckoutRequestID: #{result[:data]['CheckoutRequestID']}"

            render json: {
              status: 'success',
              message: 'Top-up initiated successfully',
              data: {
                checkout_request_id: result[:data]['CheckoutRequestID'],
                merchant_request_id: result[:data]['MerchantRequestID'],
                reference: account_reference,
                amount: amount,
                phone_number: formatted_phone,
                customer_message: result[:data]['CustomerMessage']
              }
            }
          else
            render json: {
              status: 'error',
              message: result[:message] || 'Failed to initiate top-up'
            }, status: :unprocessable_entity
          end

        rescue => e
          Rails.logger.error "Wallet top-up error: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: {
            status: 'error',
            message: 'Failed to initiate top-up',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/mpesa/topup_manual - Manual wallet top-up verification
      def topup_manual
        begin
          transaction_code = params[:transaction_code]&.upcase&.strip
          amount = params[:amount]&.to_f

          unless transaction_code.present? && amount && amount > 0
            return render json: {
              status: 'error',
              message: 'Missing required parameters'
            }, status: :unprocessable_entity
          end

          # Validate transaction code format (M-Pesa codes are 10 characters)
          unless transaction_code.match?(/^[A-Z0-9]{10}$/)
            return render json: {
              status: 'error',
              message: 'Invalid transaction code format. M-Pesa codes are 10 characters (e.g., TJ7P76Q8GV)'
            }, status: :unprocessable_entity
          end

          # Get or create wallet
          wallet = current_user.wallet || current_user.create_wallet

          unless wallet.client?
            return render json: {
              status: 'error',
              message: 'Only client wallets can be topped up'
            }, status: :forbidden
          end

          Rails.logger.info "Manual wallet top-up verification for user #{current_user.id}, amount: #{amount}, code: #{transaction_code}"

          # Check if transaction code has already been used
          existing_wallet_transaction = WalletTransaction.where(
            "reference = ? OR metadata->>'mpesa_receipt_number' = ?",
            transaction_code,
            transaction_code
          ).first

          if existing_wallet_transaction
            return render json: {
              status: 'error',
              message: 'This transaction code has already been used for a wallet top-up',
              data: {
                used_at: existing_wallet_transaction.created_at
              }
            }, status: :unprocessable_entity
          end

          # Verify with M-Pesa (for sandbox, uses simple validation)
          verification_result = MpesaService.verify_transaction_simple(
            transaction_code: transaction_code,
            amount: amount,
            phone_number: current_user.phone_number
          )

          unless verification_result[:success]
            return render json: {
              status: 'error',
              message: verification_result[:message] || 'Transaction verification failed'
            }, status: :unprocessable_entity
          end

          # Credit wallet
          ActiveRecord::Base.transaction do
            success = wallet.credit!(
              amount,
              transaction_type: 'topup',
              description: "Wallet top-up via M-Pesa (Manual verification)",
              reference: transaction_code,
              metadata: {
                mpesa_receipt_number: transaction_code,
                verification_method: 'manual',
                phone_number: current_user.phone_number,
                verified_at: Time.current.iso8601,
                verification_data: verification_result[:data]
              }
            )

            unless success
              raise ActiveRecord::Rollback, "Failed to credit wallet"
            end

            Rails.logger.info "✅ Manual wallet top-up successful: #{wallet.id} - #{amount} KES (Code: #{transaction_code})"

            render json: {
              status: 'success',
              message: 'Wallet topped up successfully',
              data: {
                amount: amount,
                transaction_code: transaction_code,
                new_balance: wallet.reload.balance,
                verified: true
              }
            }
          end

        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.error "Validation error in manual top-up: #{e.message}"
          render json: {
            status: 'error',
            message: 'Failed to process top-up',
            error: e.message
          }, status: :unprocessable_entity
        rescue => e
          Rails.logger.error "Manual wallet top-up error: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: {
            status: 'error',
            message: 'Failed to process manual top-up',
            error: Rails.env.development? ? e.message : nil
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/mpesa/wallet_callback (FIXED)
      def wallet_callback
        begin
          Rails.logger.info "Wallet top-up callback received: #{params.to_json}"

          callback_data = params[:Body][:stkCallback] rescue params

          checkout_request_id = callback_data[:CheckoutRequestID]
          result_code = callback_data[:ResultCode].to_i
          result_desc = callback_data[:ResultDesc]

          Rails.logger.info "Processing wallet callback: #{checkout_request_id} - Result Code: #{result_code}"

          # FIXED: Find wallet by checkout_request_id in metadata (like packages use payment_request_id)
          wallet = Wallet.all.find do |w|
            w.metadata.is_a?(Hash) && 
            w.metadata.dig('pending_topup', 'checkout_request_id') == checkout_request_id
          end

          unless wallet
            Rails.logger.warn "No wallet found for checkout_request_id: #{checkout_request_id}"
            return render json: { ResultCode: 0, ResultDesc: 'Accepted' }
          end

          pending_topup = wallet.metadata['pending_topup']
          amount = pending_topup['amount']

          if result_code == 0
            # Payment successful
            callback_metadata = callback_data[:CallbackMetadata][:Item] rescue []
            
            mpesa_receipt = extract_callback_value(callback_metadata, 'MpesaReceiptNumber')
            phone_number = extract_callback_value(callback_metadata, 'PhoneNumber')

            # Credit wallet (like package updates to 'pending' state)
            wallet.credit!(
              amount,
              transaction_type: 'topup',
              description: "Wallet top-up via M-Pesa",
              reference: mpesa_receipt,
              metadata: {
                mpesa_receipt_number: mpesa_receipt,
                phone_number: phone_number,
                checkout_request_id: checkout_request_id,
                completed_at: Time.current.iso8601
              }
            )

            # Clear pending topup
            current_metadata = wallet.metadata
            current_metadata.delete('pending_topup')
            wallet.update_column(:metadata, current_metadata)

            Rails.logger.info "✅ Wallet top-up completed: #{wallet.id} - #{amount} KES (Receipt: #{mpesa_receipt})"
          else
            # Payment failed - clear pending topup
            current_metadata = wallet.metadata
            current_metadata.delete('pending_topup')
            wallet.update_column(:metadata, current_metadata)

            Rails.logger.info "❌ Wallet top-up failed: #{wallet.id} - #{result_desc}"
          end

          render json: { ResultCode: 0, ResultDesc: 'Accepted' }
        rescue => e
          Rails.logger.error "Error processing wallet top-up callback: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: { ResultCode: 0, ResultDesc: 'Accepted' }
        end
      end

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

      def extract_callback_value(callback_items, key)
        return nil unless callback_items.is_a?(Array)
        
        item = callback_items.find { |i| i[:Name] == key }
        item&.dig(:Value)
      end

      def force_json_format
        request.format = :json
      end
    end
  end
end