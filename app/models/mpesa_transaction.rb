# app/models/mpesa_transaction.rb
class MpesaTransaction < ApplicationRecord
  belongs_to :user
  belongs_to :package

  validates :checkout_request_id, presence: true, uniqueness: true
  validates :merchant_request_id, presence: true
  validates :phone_number, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: %w[pending completed failed timeout] }

  scope :pending, -> { where(status: 'pending') }
  scope :completed, -> { where(status: 'completed') }
  scope :failed, -> { where(status: 'failed') }
  scope :timeout, -> { where(status: 'timeout') }

  def successful?
    status == 'completed' && result_code == 0
  end

  def failed?
    %w[failed timeout].include?(status) || (result_code.present? && result_code != 0)
  end

  def pending?
    status == 'pending'
  end
end