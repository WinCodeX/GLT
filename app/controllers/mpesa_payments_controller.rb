# app/controllers/mpesa_payments_controller.rb
class MpesaPaymentsController < ApplicationController
  before_action :authenticate_user!
  before_action :redirect_if_not_authenticated

  # GET /mpesa_payments
  def index
    @packages = current_user.packages
                           .where(state: ['pending_unpaid', 'pending'])
                           .order(created_at: :desc)
                           .limit(50)
  end

  # GET /mpesa_payments/transactions
  def transactions
    @transactions = current_user.mpesa_transactions
                               .includes(:package)
                               .order(created_at: :desc)
                               .limit(20)
    
    render json: {
      success: true,
      transactions: @transactions.map do |transaction|
        {
          id: transaction.id,
          checkout_request_id: transaction.checkout_request_id,
          amount: transaction.amount,
          status: transaction.status,
          phone_number: transaction.phone_number,
          mpesa_receipt_number: transaction.mpesa_receipt_number,
          created_at: transaction.created_at,
          package: transaction.package ? {
            id: transaction.package.id,
            code: transaction.package.code,
            receiver_name: transaction.package.receiver_name
          } : nil
        }
      end
    }
  end

  private

  def redirect_if_not_authenticated
    unless user_signed_in?
      redirect_to sign_in_path and return
    end
  end
end