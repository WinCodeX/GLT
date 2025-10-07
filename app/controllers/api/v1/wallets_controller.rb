# app/controllers/api/v1/wallets_controller.rb
module Api
  module V1
    class WalletsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_wallet, only: [:show, :transactions, :withdraw]
      before_action :force_json_format

      # GET /api/v1/wallet
      def show
        render json: {
          success: true,
          data: @wallet.as_json.merge(
            'recent_transactions' => @wallet.recent_transactions(10).as_json,
            'summary' => @wallet.transaction_summary
          )
        }
      end

      # GET /api/v1/wallet/transactions
      def transactions
        page = [params[:page]&.to_i || 1, 1].max
        per_page = [[params[:per_page]&.to_i || 20, 1].max, 50].min
        
        txns = @wallet.transactions.recent
        
        # Apply filters
        txns = txns.where(transaction_type: params[:type]) if params[:type].present?
        txns = txns.where(status: params[:status]) if params[:status].present?
        
        if params[:date_from].present?
          date_from = Date.parse(params[:date_from])
          txns = txns.where('created_at >= ?', date_from.beginning_of_day)
        end
        
        if params[:date_to].present?
          date_to = Date.parse(params[:date_to])
          txns = txns.where('created_at <= ?', date_to.end_of_day)
        end
        
        total_count = txns.count
        txns = txns.offset((page - 1) * per_page).limit(per_page)

        render json: {
          success: true,
          data: txns.as_json,
          pagination: {
            current_page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: (total_count / per_page.to_f).ceil
          }
        }
      end

      # POST /api/v1/wallet/withdraw
      def withdraw
        amount = params[:amount].to_f
        phone_number = params[:phone_number]

        if amount <= 0
          return render json: {
            success: false,
            message: 'Invalid withdrawal amount'
          }, status: :unprocessable_entity
        end

        unless @wallet.can_withdraw?(amount)
          return render json: {
            success: false,
            message: 'Insufficient balance or wallet suspended',
            available_balance: @wallet.available_balance
          }, status: :unprocessable_entity
        end

        # Minimum withdrawal amount
        if amount < 100
          return render json: {
            success: false,
            message: 'Minimum withdrawal amount is KES 100'
          }, status: :unprocessable_entity
        end

        begin
          withdrawal = @wallet.withdrawals.create!(
            amount: amount,
            phone_number: phone_number,
            withdrawal_method: 'mpesa',
            status: 'pending'
          )

          # Process withdrawal via background job
          ProcessWithdrawalJob.perform_later(withdrawal.id)

          render json: {
            success: true,
            message: 'Withdrawal request submitted',
            data: withdrawal.as_json
          }
        rescue => e
          Rails.logger.error "Withdrawal creation failed: #{e.message}"
          render json: {
            success: false,
            message: 'Failed to create withdrawal request',
            error: Rails.env.development? ? e.message : nil
          }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/wallet/withdrawals
      def withdrawals
        page = [params[:page]&.to_i || 1, 1].max
        per_page = [[params[:per_page]&.to_i || 20, 1].max, 50].min
        
        withdrawals = @wallet.withdrawals.recent
        
        # Apply filters
        withdrawals = withdrawals.where(status: params[:status]) if params[:status].present?
        
        total_count = withdrawals.count
        withdrawals = withdrawals.offset((page - 1) * per_page).limit(per_page)

        render json: {
          success: true,
          data: withdrawals.as_json,
          pagination: {
            current_page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: (total_count / per_page.to_f).ceil
          }
        }
      end

      # POST /api/v1/wallet/withdrawals/:id/cancel
      def cancel_withdrawal
        withdrawal = current_user.wallet.withdrawals.find(params[:id])
        
        unless withdrawal.can_be_cancelled?
          return render json: {
            success: false,
            message: 'Withdrawal cannot be cancelled'
          }, status: :unprocessable_entity
        end

        if withdrawal.cancel!(reason: 'Cancelled by user')
          render json: {
            success: true,
            message: 'Withdrawal cancelled successfully',
            data: withdrawal.as_json
          }
        else
          render json: {
            success: false,
            message: 'Failed to cancel withdrawal'
          }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/wallet/summary
      def summary
        period = case params[:period]
                when 'week' then 1.week
                when 'month' then 1.month
                when 'quarter' then 3.months
                else 1.month
                end

        summary = @wallet.transaction_summary(period)
        
        render json: {
          success: true,
          data: summary.merge(
            'current_balance' => @wallet.balance,
            'available_balance' => @wallet.available_balance,
            'pending_balance' => @wallet.pending_balance,
            'pending_withdrawals' => @wallet.pending_withdrawals_amount
          )
        }
      end

      private

      def force_json_format
        request.format = :json
      end

      def set_wallet
        @wallet = current_user.wallet || current_user.create_wallet
      end
    end
  end
end