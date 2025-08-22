# config/initializers/devise.rb - Fixed version

Devise.setup do |config|
  # Basic Devise configuration
  config.mailer_sender = 'noreply@packagedelivery.com'
  
  # ==> ORM configuration
  require 'devise/orm/active_record'

  # ==> Basic Authentication Configuration
  config.case_insensitive_keys = [:email]
  config.strip_whitespace_keys = [:email]
  config.skip_session_storage = [:http_auth]

  # ==> Password Configuration
  config.stretches = Rails.env.test? ? 1 : 12
  config.password_length = 8..128
  config.email_regexp = /\A[^@\s]+@[^@\s]+\z/

  # ==> Security Configuration
  config.timeout_in = 24.hours
  config.lock_strategy = :failed_attempts
  config.unlock_strategy = :both
  config.maximum_attempts = 5
  config.unlock_in = 1.hour
  config.last_attempt_warning = true
  config.reset_password_within = 6.hours

  # ==> Confirmation Configuration
  config.allow_unconfirmed_access_for = 0.days
  config.confirm_within = 3.days
  config.reconfirmable = true

  # ==> Rememberable Configuration
  config.expire_all_remember_me_on_sign_out = true
  config.rememberable_options = {
    secure: Rails.env.production?,
    httponly: true,
    same_site: :lax
  }

  # ==> Navigation Configuration
  config.navigational_formats = ['*/*', :html, :turbo_stream]
  config.sign_out_via = :delete

  # ==> Response Configuration
  config.responder.error_status = :unprocessable_entity
  config.responder.redirect_status = :see_other

  # ==> Security Configuration
  config.paranoid = true
  config.sign_out_all_scopes = true
  config.sign_in_after_change_password = true

  # ===========================================
  # 🔐 JWT CONFIGURATION (Fixed)
  # ===========================================
  
  config.jwt do |jwt|
    jwt.secret = Rails.application.credentials.jwt_secret_key || 
                 ENV['DEVISE_JWT_SECRET_KEY'] || 
                 Rails.application.secret_key_base

    jwt.dispatch_requests = [
      ['POST', %r{^/api/v1/login$}],
      ['POST', %r{^/api/v1/signup$}],
      ['POST', %r{^/api/v1/auth/google/login$}],
      ['GET', %r{^/api/v1/auth/google_oauth2/callback$}],
      ['POST', %r{^/api/v1/auth/google_oauth2/callback$}]
    ]
    
    jwt.revocation_requests = [
      ['DELETE', %r{^/api/v1/logout$}]
    ]
    
    jwt.expiration_time = 24.hours.to_i
    jwt.algorithm = 'HS256'
  end
end