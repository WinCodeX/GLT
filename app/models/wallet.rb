# app/models/wallet.rb
class Wallet < ApplicationRecord
  belongs_to :user
  has_many :transactions, class_name: 'WalletTransaction', dependent: :destroy
  has_many :withdrawals, dependent: :destroy

  enum wallet_type: {
    client: 'client',
    rider: 'rider',
    agent: 'agent',
    business: 'business'
  }

  validates :user_id, presence: true, uniqueness: true
  validates :balance, numericality: { greater_than_or_equal_to: 0 }
  validates :pending_balance, numericality: { greater_than_or_equal_to: 0 }
  validates :wallet_type, presence: true

  before_validation :set_wallet_type, on: :create

  # Scopes
  scope :active, -> { where(is_active: true) }
  scope :suspended, -> { where(is_active: false) }
  scope :with_balance, -> { where('balance > 0') }
  scope :riders, -> { where(wallet_type: 'rider') }
  scope :clients, -> { where(wallet_type: 'client') }

  # Balance Management
  def credit!(amount, transaction_type:, description:, reference: nil, metadata: {})
    raise ArgumentError, "Amount must be positive" if amount <= 0

    transaction do
      self.balance += amount
      self.total_credited += amount
      save!

      transactions.create!(
        transaction_type: transaction_type,
        amount: amount,
        balance_before: balance - amount,
        balance_after: balance,
        description: description,
        reference: reference,
        metadata: metadata,
        status: 'completed'
      )
    end

    broadcast_balance_update
    true
  rescue => e
    Rails.logger.error "Failed to credit wallet #{id}: #{e.message}"
    false
  end

  def debit!(amount, transaction_type:, description:, reference: nil, metadata: {})
    raise ArgumentError, "Amount must be positive" if amount <= 0
    raise InsufficientFundsError, "Insufficient balance" if balance < amount

    transaction do
      self.balance -= amount
      self.total_debited += amount
      save!

      transactions.create!(
        transaction_type: transaction_type,
        amount: -amount,
        balance_before: balance + amount,
        balance_after: balance,
        description: description,
        reference: reference,
        metadata: metadata,
        status: 'completed'
      )
    end

    broadcast_balance_update
    true
  rescue => e
    Rails.logger.error "Failed to debit wallet #{id}: #{e.message}"
    false
  end

  def add_pending!(amount, transaction_type:, description:, reference: nil)
    raise ArgumentError, "Amount must be positive" if amount <= 0

    transaction do
      self.pending_balance += amount
      save!

      transactions.create!(
        transaction_type: transaction_type,
        amount: amount,
        balance_before: balance,
        balance_after: balance,
        description: description,
        reference: reference,
        status: 'pending'
      )
    end

    true
  end

  def release_pending!(amount, reference:)
    raise ArgumentError, "Amount must be positive" if amount <= 0
    raise InsufficientFundsError, "Insufficient pending balance" if pending_balance < amount

    transaction do
      self.pending_balance -= amount
      self.balance += amount
      self.total_credited += amount
      save!

      pending_txn = transactions.find_by(reference: reference, status: 'pending')
      pending_txn&.update!(status: 'completed', balance_after: balance)
    end

    broadcast_balance_update
    true
  end

  def cancel_pending!(amount, reference:)
    raise ArgumentError, "Amount must be positive" if amount <= 0
    raise InsufficientFundsError, "Insufficient pending balance" if pending_balance < amount

    transaction do
      self.pending_balance -= amount
      save!

      pending_txn = transactions.find_by(reference: reference, status: 'pending')
      pending_txn&.update!(status: 'cancelled')
    end

    true
  end

  # Commission Management (for riders)
  def credit_commission!(amount, package_id:, description: nil)
    return false unless rider?

    metadata = {
      package_id: package_id,
      commission_type: 'delivery'
    }

    credit!(
      amount,
      transaction_type: 'commission',
      description: description || "Delivery commission for package ##{package_id}",
      reference: "COMM-PKG-#{package_id}",
      metadata: metadata
    )
  end

  # Withdrawal Management
  def can_withdraw?(amount)
    is_active? && balance >= amount && amount > 0
  end

  def available_balance
    balance - pending_withdrawals_amount
  end

  def pending_withdrawals_amount
    withdrawals.pending.sum(:amount)
  end

  # Statistics
  def transaction_summary(period = 1.month)
    start_date = period.ago
    txns = transactions.where('created_at >= ?', start_date)

    {
      total_credited: txns.where('amount > 0').sum(:amount),
      total_debited: txns.where('amount < 0').sum(:amount).abs,
      transaction_count: txns.count,
      commission_earned: rider? ? txns.where(transaction_type: 'commission').sum(:amount) : 0,
      pod_collected: client? ? txns.where(transaction_type: 'pod_collection').sum(:amount) : 0,
      period: period
    }
  end

  def recent_transactions(limit = 10)
    transactions.order(created_at: :desc).limit(limit)
  end

  # Suspend/Activate
  def suspend!(reason:)
    update!(is_active: false, suspended_at: Time.current, suspension_reason: reason)
    broadcast_status_update('suspended')
  end

  def activate!
    update!(is_active: true, suspended_at: nil, suspension_reason: nil)
    broadcast_status_update('active')
  end

  def as_json(options = {})
    super(options).merge(
      'available_balance' => available_balance,
      'pending_withdrawals' => pending_withdrawals_amount,
      'can_withdraw' => balance > 0 && is_active?,
      'is_rider_wallet' => rider?,
      'is_client_wallet' => client?,
      'transaction_count' => transactions.count
    )
  end

  private

  def set_wallet_type
    return if wallet_type.present?

    self.wallet_type = if user.has_role?(:rider)
                        'rider'
                      elsif user.has_role?(:agent)
                        'agent'
                      elsif user.respond_to?(:owned_businesses) && user.owned_businesses.any?
                        'business'
                      else
                        'client'
                      end
  end

  def broadcast_balance_update
    return unless user_id.present?

    ActionCable.server.broadcast(
      "user_wallet_#{user_id}",
      {
        type: 'balance_update',
        balance: balance,
        pending_balance: pending_balance,
        available_balance: available_balance,
        timestamp: Time.current.iso8601
      }
    )
  rescue => e
    Rails.logger.error "Failed to broadcast wallet update: #{e.message}"
  end

  def broadcast_status_update(status)
    return unless user_id.present?

    ActionCable.server.broadcast(
      "user_wallet_#{user_id}",
      {
        type: 'status_update',
        status: status,
        is_active: is_active?,
        timestamp: Time.current.iso8601
      }
    )
  rescue => e
    Rails.logger.error "Failed to broadcast wallet status: #{e.message}"
  end
end

# Custom error classes
class InsufficientFundsError < StandardError; end