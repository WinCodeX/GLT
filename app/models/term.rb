# app/models/term.rb
class Term < ApplicationRecord
  validates :title, presence: true
  validates :content, presence: true
  validates :version, presence: true, uniqueness: true
  validates :term_type, presence: true

  enum term_type: {
    terms_of_service: 0,
    privacy_policy: 1,
    user_agreement: 2,
    cookie_policy: 3
  }

  scope :current, -> { where(active: true) }
  scope :by_type, ->(type) { where(term_type: type) }

  before_save :deactivate_previous_versions, if: :will_save_change_to_active?

  def self.current_terms
    current.find_by(term_type: :terms_of_service)
  end

  def self.current_privacy
    current.find_by(term_type: :privacy_policy)
  end

  private

  def deactivate_previous_versions
    return unless active?
    
    Term.where(term_type: term_type, active: true)
        .where.not(id: id)
        .update_all(active: false)
  end
end