# app/models/withdrawal.rb
class Withdrawal < ApplicationRecord
  belongs_to :wallet
  has_one :user, through: :wallet
  has_one :wallet_transaction, dependent: :destroy

  enum status: {
    pending: 'pending',
    processing: 'processing',
    completed: 'completed',
    failed: 'failed',
    cancelled: 'cancelled'
  }

  enum withdrawal_method: {
    mpesa: 'mpesa',
    bank_transfer: 'bank_transfer'
  }

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :phone_number, presence: true, if: :mpesa?
  validates :status, presence: true
  validates :withdrawal_method, presence: true

  before_validation :set_defaults, on: :create
  after_create :deduct_from_wallet
  after_update :handle_status_change, if: :saved_change_to_status?

  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :today, -> { where('created_at >= ?', Time.current.beginning_of_day) }
  scope :this_week, -> { where('created_at >= ?', 1.week.ago) }
  scope :this_month, -> { where('created_at >= ?', 1.month.ago) }

  # Process withdrawal via M-Pesa B2C
  def process_mpesa_withdrawal!
    return false unless pending? && mpesa?

    update!(status: 'processing', processed_at: Time.current)

    result = MpesaService.initiate_b2c_payment(
      phone_number: phone_number,
      amount: amount,
      reference: reference_number,
      remarks: "Wallet withdrawal - #{reference_number}"
    )

    if result[:success]
      update!(
        mpesa_receipt_number: result[:data]['ConversationID'],
        mpesa_request_id: result[:data]['OriginatorConversationID'],
        metadata: (metadata || {}).merge(mpesa_response: result[:data])
      )
      
      Rails.logger.info "Withdrawal #{id} processed successfully via M-Pesa"
      true
    else
      handle_failure!(result[:message])
      false
    end
  rescue => e
    Rails.logger.error "Failed to process M-Pesa withdrawal #{id}: #{e.message}"
    handle_failure!(e.message)
    false
  end

  # Mark as completed (called from M-Pesa callback)
  def mark_completed!(receipt_number: nil)
    return false unless processing?

    transaction do
      update!(
        status: 'completed',
        completed_at: Time.current,
        mpesa_receipt_number: receipt_number || mpesa_receipt_number
      )

      # Create wallet transaction
      create_wallet_transaction!(
        wallet: wallet,
        transaction_type: 'withdrawal',
        amount: -amount,
        balance_before: wallet.balance + amount,
        balance_after: wallet.balance,
        description: "Withdrawal to #{phone_number}",
        reference: reference_number,
        status: 'completed'
      )

      notify_completion
    end

    true
  rescue => e
    Rails.logger.error "Failed to mark withdrawal #{id} as completed: #{e.message}"
    false
  end

  # Handle failure
  def handle_failure!(reason)
    transaction do
      update!(
        status: 'failed',
        failure_reason: reason,
        failed_at: Time.current
      )

      # Refund to wallet
      wallet.balance += amount
      wallet.save!

      notify_failure
    end
  rescue => e
    Rails.logger.error "Failed to handle withdrawal failure for #{id}: #{e.message}"
  end

  # Cancel withdrawal
  def cancel!(reason: nil)
    return false unless pending?

    transaction do
      update!(
        status: 'cancelled',
        failure_reason: reason,
        failed_at: Time.current
      )

      # Refund to wallet
      wallet.balance += amount
      wallet.save!

      notify_cancellation
    end

    true
  rescue => e
    Rails.logger.error "Failed to cancel withdrawal #{id}: #{e.message}"
    false
  end

  def can_be_cancelled?
    pending?
  end

  def can_be_retried?
    failed? && created_at > 24.hours.ago
  end

  def display_amount
    "KES #{amount.to_f.round(2)}"
  end

  def formatted_phone_number
    return phone_number unless phone_number.present?
    
    # Format Kenyan phone numbers
    if phone_number.match(/^\+254(\d{9})$/)
      num = $1
      "0#{num[0..2]} #{num[3..5]} #{num[6..8]}"
    else
      phone_number
    end
  end

  def as_json(options = {})
    super(options).merge(
      'display_amount' => display_amount,
      'formatted_phone_number' => formatted_phone_number,
      'can_be_cancelled' => can_be_cancelled?,
      'can_be_retried' => can_be_retried?,
      'wallet_type' => wallet.wallet_type,
      'user_name' => user.display_name
    )
  end

  private

  def set_defaults
    self.reference_number ||= generate_reference_number
    self.withdrawal_method ||= 'mpesa'
    self.status ||= 'pending'
  end

  def generate_reference_number
    "WD-#{wallet_id}-#{Time.current.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(3).upcase}"
  end

  def deduct_from_wallet
    return unless pending?

    if wallet.balance >= amount
      wallet.balance -= amount
      wallet.save!
    else
      errors.add(:amount, 'Insufficient wallet balance')
      throw :abort
    end
  rescue => e
    Rails.logger.error "Failed to deduct from wallet for withdrawal #{id}: #{e.message}"
    throw :abort
  end

  def handle_status_change
    case status
    when 'completed'
      notify_completion
    when 'failed'
      notify_failure
    when 'cancelled'
      notify_cancellation
    end
  end

  def notify_completion
    ActionCable.server.broadcast(
      "user_wallet_#{wallet.user_id}",
      {
        type: 'withdrawal_completed',
        withdrawal: {
          id: id,
          amount: amount,
          display_amount: display_amount,
          reference: reference_number,
          completed_at: completed_at.iso8601
        },
        timestamp: Time.current.iso8601
      }
    )

    create_notification('Withdrawal Completed', '✅')
  rescue => e
    Rails.logger.error "Failed to notify withdrawal completion: #{e.message}"
  end

  def notify_failure
    ActionCable.server.broadcast(
      "user_wallet_#{wallet.user_id}",
      {
        type: 'withdrawal_failed',
        withdrawal: {
          id: id,
          amount: amount,
          display_amount: display_amount,
          reference: reference_number,
          reason: failure_reason
        },
        timestamp: Time.current.iso8601
      }
    )

    create_notification('Withdrawal Failed', '❌')
  rescue => e
    Rails.logger.error "Failed to notify withdrawal failure: #{e.message}"
  end

  def notify_cancellation
    ActionCable.server.broadcast(
      "user_wallet_#{wallet.user_id}",
      {
        type: 'withdrawal_cancelled',
        withdrawal: {
          id: id,
          amount: amount,
          display_amount: display_amount,
          reference: reference_number
        },
        timestamp: Time.current.iso8601
      }
    )

    create_notification('Withdrawal Cancelled', 'ℹ️')
  rescue => e
    Rails.logger.error "Failed to notify withdrawal cancellation: #{e.message}"
  end

  def create_notification(title, icon)
    return unless defined?(Notification)

    Notification.create!(
      user: user,
      notification_type: 'wallet_withdrawal',
      title: "#{icon} #{title}",
      message: "#{display_amount} withdrawal to #{formatted_phone_number}",
      data: {
        withdrawal_id: id,
        amount: amount,
        reference: reference_number,
        status: status
      }
    )
  rescue => e
    Rails.logger.error "Failed to create withdrawal notification: #{e.message}"
  end
end