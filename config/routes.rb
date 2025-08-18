# config/routes.rb - Fixed with proper Active Storage support
Rails.application.routes.draw do
  # ==========================================
  # 🔐 AUTHENTICATION (Devise) - Must be first
  # ==========================================
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

  # ==========================================
  # 🗂️ ACTIVE STORAGE ROUTES (Critical - must be early!)
  # ==========================================
  # These routes handle avatar/file uploads and downloads
  # Rails normally mounts these automatically, but we need to be explicit
  # when we have catch-all routes that might interfere
  
  # This ensures Active Storage routes are properly mounted
  direct :rails_blob_redirect do |blob, options|
    route_for(:rails_service_blob, blob.signed_id, blob.filename, options)
  end

  # ==========================================
  # 🌐 PUBLIC ENDPOINTS (No Authentication Required)
  # ==========================================
  scope :public do
    get 'track/:code', to: 'public/tracking#show', as: :public_package_tracking
    get 'track/:code/status', to: 'public/tracking#status'
    get 'track/:code/timeline', to: 'public/tracking#timeline'
    get 'track/:code/qr', to: 'public/tracking#qr_code'
  end

  # ==========================================
  # 📱 API v1 - Main Application Routes
  # ==========================================
  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      
      # ==========================================
      # 🔐 USER MANAGEMENT & AUTHENTICATION
      # ==========================================
      get 'users/me', to: 'users#me'
      get 'users', to: 'users#index'
      get 'me', to: 'me#show'
      put 'me/avatar', to: 'me#update_avatar'
      delete 'me/avatar', to: 'me#destroy_avatar'
      get 'ping', to: 'status#ping'
      get 'users/search', to: 'users#search'
      post 'typing_status', to: 'typing_status#create'
      patch 'users/update', to: 'users#update'
      patch 'users/:id/assign_role', to: 'users#assign_role'
      post :google_login, to: 'sessions#google_login'

      # User Analytics & Stats
      get 'users/scanning_stats', to: 'users#scanning_stats'
      get 'users/scan_history', to: 'users#scan_history'
      get 'users/performance_metrics', to: 'users#performance_metrics'
      get 'users/dashboard_stats', to: 'users#dashboard_stats'

      # ==========================================
      # 🏢 BUSINESS MANAGEMENT
      # ==========================================
      resources :invites, only: [:create] do
        collection do
          post :accept
        end
      end

      resources :businesses, only: [:create, :index, :show]

      # ==========================================
      # 📋 FORM DATA ENDPOINTS
      # ==========================================
      namespace :form_data do
        get :areas
        get :agents
        get :locations
        get :package_form_data
        get :package_states
        get :delivery_types
      end

      # ==========================================
      # 📦 PACKAGE MANAGEMENT
      # ==========================================
      resources :packages, only: [:index, :create, :show, :update, :destroy] do
        member do
          get :validate
          get :qr_code
          get :tracking_page
          get :scan_info
          post :pay
          patch :submit
          patch :cancel
          get :timeline
          get :print_history
        end
        
        collection do
          get :search
          get :advanced_search
          get :stats
          get :analytics
          get :pricing
          post :calculate_cost
          post :bulk_create
          patch :bulk_update
        end
      end

      # ==========================================
      # 📱 SCANNING SYSTEM
      # ==========================================
      scope :scanning do
        post :scan_action
        get :package_details
        post :bulk_scan
        get 'package/:package_code/actions', to: 'scanning#available_actions'
        post 'package/:package_code/validate', to: 'scanning#validate_action'
        get 'package/:package_code/scan_info', to: 'scanning#package_scan_info'
        get :scan_statistics
        get :recent_scans
        get :search_packages
        post :sync_offline_actions
        get :sync_status
        delete :clear_offline_data
      end

      get 'packages/search', to: 'packages#search'

      # ==========================================
      # 🖨️ PRINTING SYSTEM
      # ==========================================
      scope :printing do
        post 'package/:package_code/label', to: 'printing#generate_label'
        post 'package/:package_code/print', to: 'printing#print_label'
        get 'package/:package_code/print_history', to: 'printing#print_history'
        get :print_queue
        get :printer_status
        get :print_settings
        patch :update_settings
        post :bulk_print
        get :bulk_print_status
      end

      # ==========================================
      # 📍 TRACKING & EVENTS
      # ==========================================
      resources :tracking_events, only: [:index, :show, :create] do
        collection do
          get :recent
          get :by_package
          get :by_user
          get :timeline
        end
      end

      scope :tracking do
        get 'package/:package_code', to: 'tracking#package_status'
        get 'package/:package_code/live', to: 'tracking#live_tracking'
        get 'package/:package_code/timeline', to: 'tracking#detailed_timeline'
        get 'package/:package_code/location', to: 'tracking#current_location'
        post :batch_status, to: 'tracking#batch_package_status'
      end

      # ==========================================
      # 🏢 LOCATION & PERSONNEL MANAGEMENT
      # ==========================================
      resources :areas, only: [:index, :create, :show, :update, :destroy] do
        member do
          get :packages
          get :routes
          get :agents
          get :scan_activity
        end
        collection do
          post :bulk_create
          get :with_stats
        end
      end

      resources :locations, only: [:index, :create, :show] do
        member do
          get :areas
          get :package_volume
        end
      end

      resources :agents, only: [:index, :create, :show, :update] do
        member do
          get :packages
          get :performance
          get :scan_history
          patch :toggle_active
        end
        collection do
          get :active
          get :by_area
          get :performance_report
        end
      end

      resources :riders, only: [:index, :create, :show, :update] do
        member do
          get :packages
          get :performance
          get :scan_history
          get :route_activity
          patch :toggle_active
        end
        collection do
          get :active
          get :by_area
          get :performance_report
        end
      end

      resources :warehouse_staff, only: [:index, :create, :show, :update] do
        member do
          get :packages
          get :performance
          get :scan_history
          get :processing_queue
          patch :toggle_active
        end
        collection do
          get :active
          get :by_location
          get :performance_report
        end
      end

      # ==========================================
      # 💰 PRICING SYSTEM
      # ==========================================
      resources :prices, only: [:index, :create, :show, :update, :destroy] do
        member do
          patch :update_cost
        end
        collection do
          get :calculate
          get :search
          post :bulk_create
          get :matrix
          get :fragile_surcharge
        end
      end

      # Dedicated pricing endpoints
      get 'pricing', to: 'packages#calculate_pricing'
      post 'pricing/calculate', to: 'packages#calculate_pricing'
      get 'pricing/matrix', to: 'prices#pricing_matrix'
      get 'pricing/fragile', to: 'prices#fragile_pricing'

      # ==========================================
      # 💬 CONVERSATIONS & SUPPORT
      # ==========================================
      resources :conversations, only: [:index, :show] do
        member do
          patch :close
          patch :reopen
          patch :assign
        end
        
        resources :messages, only: [:index, :create] do
          collection do
            patch :mark_read
          end
        end
      end

      post 'conversations/support_ticket', to: 'conversations#create_support_ticket'
      get 'conversations/active_support', to: 'conversations#active_support'
      get 'conversations/package_support', to: 'conversations#package_support'

      # ==========================================
      # 📊 ANALYTICS & REPORTING
      # ==========================================
      scope :analytics do
        get :package_overview
        get :delivery_performance
        get :fragile_package_stats
        get :rider_performance
        get :agent_performance
        get :warehouse_performance
        get :user_activity
        get :scan_volume
        get :scan_errors
        get :offline_sync_stats
        get :role_based_activity
        get :revenue_analysis
        get :cost_breakdown
        get :fragile_surcharge_impact
        get :route_performance
        get :area_activity
        get :warehouse_efficiency
        get :trends
        get :forecasting
      end

      # ==========================================
      # 👥 ROLE-BASED ENDPOINTS
      # ==========================================
      scope :client do
        get :packages, to: 'packages#index'
        get :tracking, to: 'tracking#client_packages'
        post :confirm_receipt, to: 'scanning#scan_action'
      end

      scope :agent do
        get :packages, to: 'packages#agent_packages'
        get :print_queue, to: 'printing#agent_print_queue'
        post :print_labels, to: 'scanning#bulk_scan'
        get :performance, to: 'analytics#agent_performance'
      end

      scope :rider do
        get :packages, to: 'packages#rider_packages'
        get :routes, to: 'analytics#rider_routes'
        post :collect_packages, to: 'scanning#bulk_scan'
        post :deliver_packages, to: 'scanning#bulk_scan'
        get :performance, to: 'analytics#rider_performance'
      end

      scope :warehouse do
        get :packages, to: 'packages#warehouse_packages'
        get :processing_queue, to: 'packages#processing_queue'
        post :process_packages, to: 'scanning#bulk_scan'
        get :inventory, to: 'packages#warehouse_inventory'
        get :performance, to: 'analytics#warehouse_performance'
      end

      # Admin endpoints
      namespace :admin do
        resources :conversations, only: [:index, :show] do
          member do
            patch :assign_to_me
            patch :transfer
            patch 'status', to: 'conversations#update_status'
          end
        end
        
        get :all_packages, to: 'packages#admin_index'
        get :system_overview, to: 'analytics#system_overview'
        get :user_management, to: 'users#admin_index'
        post :bulk_actions, to: 'scanning#admin_bulk_actions'
        get :audit_logs, to: 'system#audit_logs'
        
        # Admin analytics
        get 'analytics/scanning', to: 'analytics#scanning_overview'
        get 'analytics/packages', to: 'analytics#package_analytics'
        get 'analytics/performance', to: 'analytics#performance_metrics'
        get 'analytics/fragile_packages', to: 'analytics#fragile_package_analytics'
      end

      # ==========================================
      # 🔧 SYSTEM CONFIGURATION
      # ==========================================
      scope :settings do
        get :print_configuration
        patch :update_print_config
        get :scan_configuration
        patch :update_scan_config
        get :pricing_configuration
        patch :update_pricing_config
        get :fragile_settings
        patch :update_fragile_settings
        get :sync_settings
        patch :update_sync_settings
        get :role_permissions
        patch :update_role_permissions
      end

      scope :system do
        get :health, to: 'system#health_check'
        get :printer_health
        get :database_health
        get :stats, to: 'system#system_statistics'
        get :performance, to: 'system#performance_metrics'
        get :job_status, to: 'system#background_job_status'
        get :sync_queue, to: 'system#sync_queue_status'
        get :logs, to: 'system#recent_logs'
        get :error_logs
        get :scan_logs, to: 'system#scanning_logs'
      end

      # ==========================================
      # 🏥 STATUS & HEALTH
      # ==========================================
      get 'status', to: 'status#ping'
      get 'health', to: 'status#ping'
    end
  end

  # ==========================================
  # 📱 MOBILE APP ENDPOINTS
  # ==========================================
  scope :mobile do
    namespace :v1 do
      get 'packages/recent', to: 'mobile#recent_packages'
      get 'packages/my_scans', to: 'mobile#my_recent_scans'
      post 'quick_scan', to: 'mobile#quick_scan'
      post 'quick_print', to: 'mobile#quick_print'
      post 'sync', to: 'mobile#sync_data'
      get 'sync_status', to: 'mobile#sync_status'
      get 'dashboard', to: 'mobile#dashboard_data'
      get 'notifications', to: 'mobile#notifications'
      get 'role_dashboard', to: 'mobile#role_based_dashboard'
      get 'quick_actions', to: 'mobile#role_quick_actions'
    end
  end

  # ==========================================
  # 🔗 WEBHOOKS
  # ==========================================
  scope :webhooks do
    post 'payment/success', to: 'webhooks#payment_success'
    post 'payment/failed', to: 'webhooks#payment_failed'
    post 'tracking/update', to: 'webhooks#tracking_update'
    post 'delivery/notification', to: 'webhooks#delivery_notification'
    post 'printer/status', to: 'webhooks#printer_status_update'
    post 'printer/error', to: 'webhooks#printer_error'
    post 'scan/completed', to: 'webhooks#scan_completed'
    post 'bulk_scan/completed', to: 'webhooks#bulk_scan_completed'
  end

  # ==========================================
  # 🏥 HEALTH CHECKS
  # ==========================================
  get "up" => "rails/health#show", as: :rails_health_check
  get "health/db" => "health#database", as: :database_health_check
  get "health/redis" => "health#redis", as: :redis_health_check if defined?(Redis)
  get "health/jobs" => "health#background_jobs", as: :jobs_health_check
  get "health/scanning" => "health#scanning_system", as: :scanning_health_check

  # ==========================================
  # 📱 PWA SUPPORT
  # ==========================================
  get '/manifest.json', to: 'pwa#manifest'
  get '/sw.js', to: 'pwa#service_worker'
  get '/offline', to: 'pwa#offline'

  # ==========================================
  # 🔀 ROOT & DOCUMENTATION
  # ==========================================
  root 'api/v1/status#ping'
  get '/docs', to: 'documentation#index'
  get '/api/docs', to: 'documentation#api_docs'
  
  # Legacy compatibility
  get 'api/v1/track/:code', to: 'api/v1/packages#public_tracking', as: :package_tracking

  # ==========================================
  # 🚫 CATCH-ALL (FIXED - More specific to avoid Active Storage)
  # ==========================================
  # ✅ IMPORTANT: This catch-all now excludes Active Storage paths
  # Active Storage paths include:
  # - /rails/active_storage/blobs/*
  # - /rails/active_storage/representations/*
  # - /rails/active_storage/disk/*
  # - /rails/active_storage/direct_uploads/*
  
  # More specific catch-all that doesn't interfere with Active Storage
  constraints(->(request) { 
    # Don't catch Active Storage paths
    !request.path.start_with?('/rails/active_storage/') &&
    # Don't catch asset paths
    !request.path.start_with?('/assets/') &&
    # Don't catch pack paths (Webpacker)
    !request.path.start_with?('/packs/') &&
    # Don't catch favicon
    !request.path.include?('favicon')
  }) do
    match '*unmatched', to: 'application#route_not_found', via: :all
  end
end