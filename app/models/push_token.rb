# app/models/push_token.rb
class PushToken < ApplicationRecord
  belongs_to :user
  
  validates :token, presence: true, uniqueness: { scope: :user_id }
  validates :platform, presence: true, inclusion: { in: ['expo', 'fcm', 'apns'] }
  
  scope :active, -> { where(active: true) }
  scope :expo_tokens, -> { where(platform: 'expo') }
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
  
  private
  
  def deactivate_old_tokens
    user.push_tokens.where(platform: platform).update_all(active: false)
  end
end