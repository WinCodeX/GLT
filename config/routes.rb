Rails.application.routes.draw do
  # Devise authentication (login/logout)
  devise_for :users,
  path: 'api/v1',
  path_names: {
    sign_in: 'login',
    sign_out: 'logout',
    sign_up: 'signup' # <-- add this line
  },
  controllers: {
    sessions: 'api/v1/sessions',
    registrations: 'api/v1/registrations' # <-- this too
  }
devise_scope :user do
  post 'api/v1/signup', to: 'api/v1/registrations#create'
end

  namespace :api do
    namespace :v1 do
      # User profile and management
      get 'users/me', to: 'users#me'
      get 'users', to: 'users#index'
      get 'me', to: 'me#show', defaults: { format: :json }
      put 'me/avatar', to: 'me#update_avatar'
      get 'ping', to: 'status#ping', defaults: { format: :json }
      get 'users/search', to: 'users#search'
      post 'typing_status', to: 'typing_status#create'

      

      patch 'users/update', to: 'users#update'
      patch 'users/:id/assign_role', to: 'users#assign_role'

     post :google_login, to: 'sessions#google_login'

      # ✅ Business Invites
      resources :invites, only: [:create], defaults: { format: :json } do
        collection do
          post :accept
        end
      end

      # ✅ Businesses
      resources :businesses, only: [:create, :index, :show], defaults: { format: :json }
    
      # ✅ Resources
      resources :packages, only: [:index, :create, :show]
      # ✅ locations
    resources :locations, only: [:index, :create]
      # ✅ Areas
    resources :areas, only: [:index, :create]
      # ✅ Agents
    resources :agents, only: [:index, :create]
      # ✅ Prices
    resources :prices, only: [:index, :create]
    end
  end

  # Health check endpoint
  get "up" => "rails/health#show", as: :rails_health_check
end