# app/models/wallet_transaction.rb
class WalletTransaction < ApplicationRecord
  belongs_to :wallet
  belongs_to :package, optional: true
  belongs_to :withdrawal, optional: true

  enum transaction_type: {
    commission: 'commission',
    pod_collection: 'pod_collection',
    collection_payment: 'collection_payment',
    withdrawal: 'withdrawal',
    refund: 'refund',
    adjustment: 'adjustment',
    bonus: 'bonus',
    penalty: 'penalty'
  }

  enum status: {
    pending: 'pending',
    completed: 'completed',
    failed: 'failed',
    cancelled: 'cancelled',
    reversed: 'reversed'
  }

  validates :transaction_type, presence: true
  validates :amount, presence: true, numericality: true
  validates :balance_before, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :balance_after, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :status, presence: true

  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :today, -> { where('created_at >= ?', Time.current.beginning_of_day) }
  scope :this_week, -> { where('created_at >= ?', 1.week.ago) }
  scope :this_month, -> { where('created_at >= ?', 1.month.ago) }
  scope :credits, -> { where('amount > 0') }
  scope :debits, -> { where('amount < 0') }
  scope :by_type, ->(type) { where(transaction_type: type) }

  after_create :notify_user

  def credit?
    amount > 0
  end

  def debit?
    amount < 0
  end

  def absolute_amount
    amount.abs
  end

  def transaction_icon
    case transaction_type
    when 'commission'
      '💰'
    when 'pod_collection', 'collection_payment'
      '📦'
    when 'withdrawal'
      '🏦'
    when 'refund'
      '↩️'
    when 'bonus'
      '🎁'
    when 'penalty'
      '⚠️'
    else
      '💳'
    end
  end

  def display_amount
    prefix = credit? ? '+' : ''
    "#{prefix}KES #{absolute_amount.to_f.round(2)}"
  end

  def as_json(options = {})
    super(options).merge(
      'is_credit' => credit?,
      'is_debit' => debit?,
      'absolute_amount' => absolute_amount,
      'display_amount' => display_amount,
      'transaction_icon' => transaction_icon,
      'user_id' => wallet.user_id,
      'package_code' => package&.code
    )
  end

  private

  def notify_user
    return unless wallet&.user_id && completed?

    ActionCable.server.broadcast(
      "user_wallet_#{wallet.user_id}",
      {
        type: 'new_transaction',
        transaction: {
          id: id,
          transaction_type: transaction_type,
          amount: amount,
          display_amount: display_amount,
          description: description,
          created_at: created_at.iso8601,
          is_credit: credit?
        },
        balance: wallet.balance,
        timestamp: Time.current.iso8601
      }
    )

    # Create notification for significant transactions
    if defined?(Notification) && (absolute_amount >= 100 || transaction_type.in?(['commission', 'pod_collection']))
      create_transaction_notification
    end
  rescue => e
    Rails.logger.error "Failed to notify user about transaction #{id}: #{e.message}"
  end

  def create_transaction_notification
    return unless wallet&.user

    title = case transaction_type
            when 'commission'
              "💰 Commission Earned"
            when 'pod_collection'
              "📦 Payment Collected"
            when 'collection_payment'
              "💵 Collection Payment Received"
            when 'withdrawal'
              "🏦 Withdrawal Processed"
            when 'refund'
              "↩️ Refund Received"
            else
              "💳 Wallet Transaction"
            end

    Notification.create!(
      user: wallet.user,
      notification_type: 'wallet_transaction',
      title: title,
      message: "#{display_amount} - #{description}",
      data: {
        transaction_id: id,
        transaction_type: transaction_type,
        amount: amount,
        balance: wallet.balance,
        package_id: package_id,
        package_code: package&.code
      }
    )
  rescue => e
    Rails.logger.error "Failed to create transaction notification: #{e.message}"
  end
end