# app/models/push_token.rb
class PushToken < ApplicationRecord
  belongs_to :user
  
  validates :token, presence: true, uniqueness: { scope: :user_id }
  validates :platform, presence: true, inclusion: { in: ['fcm', 'apns'] } # Removed 'expo'
  
  scope :active, -> { where(active: true) }
  scope :fcm_tokens, -> { where(platform: 'fcm') }
  scope :apns_tokens, -> { where(platform: 'apns') }
  scope :stale, -> { where('last_used_at < ?', 30.days.ago) }
  
  before_create :deactivate_old_tokens
  
  def self.cleanup_expired_tokens
    stale.destroy_all
  end
  
  def mark_as_used!
    touch(:last_used_at)
  end
  
  def mark_as_failed!
    increment!(:failure_count)
    update!(active: false) if failure_count >= 5
  end
  
  def fcm_token?
    platform == 'fcm'
  end
  
  def apns_token?
    platform == 'apns'
  end
  
  # Validate token format on creation
  def validate_token_format
    case platform
    when 'fcm'
      unless token.length > 100 && token.match?(/^[A-Za-z0-9_:-]+$/)
        errors.add(:token, 'Invalid FCM token format')
      end
    when 'apns'
      unless token.length == 64 && token.match?(/^[a-fA-F0-9]+$/)
        errors.add(:token, 'Invalid APNS token format')
      end
    end
  end
  
  private
  
  def deactivate_old_tokens
    user.push_tokens.where(platform: platform).update_all(active: false)
  end
end