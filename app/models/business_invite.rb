class BusinessInvite < ApplicationRecord
  belongs_to :inviter, class_name: 'User'
  belongs_to :business

  before_create :generate_unique_code

  private

  def generate_unique_code
    begin
      self.code = 6.times.map { rand(0..9) }.join
    end while self.class.exists?(code: code)
  end
end