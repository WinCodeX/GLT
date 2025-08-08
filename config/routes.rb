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
    
      # ✅ Enhanced Resources with Full CRUD and Additional Features
      
      # 📦 PACKAGES - Enhanced with QR codes, tracking, search, etc.
      resources :packages, only: [:index, :create, :show, :update, :destroy] do
        member do
          get :validate          # Validate package by code
          get :qr_code          # Generate QR code
          get :tracking_page    # Full tracking information
          post :pay             # Process payment
          patch :submit         # Submit for delivery
        end
        collection do
          get :search           # Search packages by code
          get :stats           # Package statistics
        end
      end

      # 🏢 AREAS - Enhanced with package management and route analytics
      resources :areas, only: [:index, :create, :show, :update, :destroy] do
        member do
          get :packages         # Get packages for this area
          get :routes          # Get route statistics
        end
        collection do
          post :bulk_create     # Create multiple areas at once
        end
      end

      # 📍 LOCATIONS - Keep existing functionality
      resources :locations, only: [:index, :create, :show]

      # 👥 AGENTS - Keep existing functionality  
      resources :agents, only: [:index, :create, :show]

      # 💰 PRICES - Keep existing functionality
      resources :prices, only: [:index, :create, :show]

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

      # 🔍 Public tracking endpoint (no authentication required)
      get 'track/:code', to: 'packages#public_tracking', as: :package_tracking
    end
  end

  # Health check endpoint
  get "up" => "rails/health#show", as: :rails_health_check
end