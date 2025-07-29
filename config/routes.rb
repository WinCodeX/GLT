Rails.application.routes.draw do
  # Devise authentication (login/logout)
  devise_for :users,
    path: 'api/v1',
    path_names: {
      sign_in: 'login',
      sign_out: 'logout'
    },
    controllers: {
      sessions: 'api/v1/sessions'
    }

  namespace :api do
    namespace :v1 do
      # User profile and management
      get 'users/me', to: 'users#me'
      get 'users', to: 'users#index'
      patch 'users/update', to: 'users#update'
      patch 'users/:id/assign_role', to: 'users#assign_role'
    end
  end

  # Health check endpoint
  get "up" => "rails/health#show", as: :rails_health_check
end