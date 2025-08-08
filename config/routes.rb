# config/routes.rb
Rails.application.routes.draw do
  # Devise authentication (login/logout)
  devise_for :users,
  path: 'api/v1',
  path_names: {
    sign_in: 'login',
    sign_out: 'logout',
    sign_up: 'signup'
  },
  controllers: {
    sessions: 'api/v1/sessions',
    registrations: 'api/v1/registrations'
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
      resources :locations, only: [:index, :create]
      resources :areas, only: [:index, :create]
      resources :agents, only: [:index, :create]
      resources :prices, only: [:index, :create]

      # ✅ CONVERSATIONS AND SUPPORT SYSTEM
      resources :conversations, only: [:index, :show] do
        member do
          patch :close
          patch :reopen
        end
        
        # Messages nested under conversations
        resources :messages, only: [:index, :create] do
          collection do
            patch :mark_read
          end
        end
      end

      # Support ticket specific endpoints
      post 'conversations/support_ticket', to: 'conversations#create_support_ticket'
      get 'conversations/active_support', to: 'conversations#active_support'

      # Admin conversation management (for support agents)
      namespace :admin do
        resources :conversations, only: [:index, :show] do
          member do
            patch :assign_to_me
            patch :transfer
            patch 'status', to: 'conversations#update_status'
          end
        end
      end
    end
  end

  # Health check endpoint
  get "up" => "rails/health#show", as: :rails_health_check
end