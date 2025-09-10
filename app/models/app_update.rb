class AppUpdate < ApplicationRecord
  validates :version, presence: true, uniqueness: true
  validates :update_id, presence: true, uniqueness: true
  validates :bundle_url, presence: true, if: :published?

  scope :published, -> { where(published: true) }
  scope :latest_first, -> { order(created_at: :desc) }

  before_validation :generate_update_id, on: :create

  def self.latest
    latest_first.first
  end

  def version_number
    Gem::Version.new(version)
  rescue ArgumentError
    Gem::Version.new('0.0.0')
  end

  def self.current_version
    published.latest&.version || '1.0.0'
  end

  def self.has_newer_version?(current_version)
    latest_update = published.latest
    return false unless latest_update
    
    begin
      Gem::Version.new(latest_update.version) > Gem::Version.new(current_version)
    rescue ArgumentError
      false
    end
  end

  def increment_download_count!
    increment!(:download_count)
  end

  def published?
    read_attribute(:published) == true
  end

  private

  def generate_update_id
    self.update_id ||= SecureRandom.uuid
  end
end