# config/initializers/omniauth.rb

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
           Rails.application.credentials.dig(:google_oauth, :client_id),
           Rails.application.credentials.dig(:google_oauth, :client_secret),
           {
             scope: 'email,profile',
             prompt: 'select_account',
             image_aspect_ratio: 'square',
             image_size: 50,
             access_type: 'offline',
             approval_prompt: '',
             provider_ignores_state: false,
             # Security configurations
             authorize_params: {
               access_type: 'offline',
               approval_prompt: ''
             },
             # Callback configuration
             callback_path: '/api/v1/auth/google_oauth2/callback'
           }
end

# CSRF Protection
OmniAuth.config.request_validation_phase = OmniAuth::AuthenticityTokenProtection.new(
  min_token_length: 15,
  raise_on_failure: true
)

# Logging for debugging (remove in production)
OmniAuth.config.logger = Rails.logger

# On failure, redirect to failure handler
OmniAuth.config.on_failure = Proc.new { |env|
  OmniAuth::FailureEndpoint.new(env).redirect_to_failure
}