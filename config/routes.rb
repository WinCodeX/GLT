# config/routes.rb - UPDATED: Enhanced with comprehensive pricing system and new delivery types

Rails.application.routes.draw do
  # ==========================================
  # 🔐 WEB AUTHENTICATION (Simple Sign In)
  # ==========================================
  

 #Admin namespace for updates management
  namespace :admin do
    resources :updates do
      member do
        patch :publish
        patch :unpublish
      end
      collection do
        post :upload_bundle_only
        get :stats
      end
    end
  end


  # Web-based admin authentication routes (if using Devise)
  
    get '/admin/sign_in', to: 'sessions#new', as: :sign_in
    post '/admin/sign_in', to: 'sessions#create'
    delete '/admin/sign_out', to: 'sessions#destroy', as: :sign_out
  

  # Admin dashboard root
  get '/admin', to: 'admin/updates#index'


  # Simple web-based sign in/out
  get '/sign_in', to: 'sessions#new', as: :sign_in
  post '/sign_in', to: 'sessions#create'
  delete '/sign_out', to: 'sessions#destroy', as: :sign_out
  get '/logout', to: 'sessions#destroy'  # Alternative logout path

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
      registrations: 'api/v1/registrations',
      omniauth_callbacks: 'api/v1/omniauth_callbacks'
    },
    defaults: { format: :json }  
  
  devise_scope :user do
    post 'api/v1/signup', to: 'api/v1/registrations#create'
  end

  # ==========================================
  # 💳 MPESA PAYMENT INTEGRATION
  # ==========================================
  
  resources :mpesa_payments, only: [:index] do
    collection do
      get :transactions
    end
  end

  scope :mpesa do
    post 'stk_push', to: 'mpesa#stk_push'
    post 'query_status', to: 'mpesa#query_status'
    post '/mpesa/callback', to: 'mpesa#callback'
    post '/mpesa/timeout', to: 'mpesa#timeout'
  end

  # ==========================================
  # 🔐 NEW: EXPO-AUTH-SESSION OAUTH ROUTES
  # ==========================================
  
  namespace :api do
    namespace :auth do
      # OAuth 2.0 endpoints for expo-auth-session
      get 'authorize', to: 'oauth#authorize'           # Initial OAuth authorization
      get 'callback', to: 'oauth#callback'             # Google OAuth callback
      post 'token', to: 'oauth#token_exchange'         # Token exchange endpoint
      get 'session', to: 'oauth#session'               # Get current session
      post 'logout', to: 'oauth#logout'                # Logout endpoint
      post 'refresh', to: 'oauth#refresh_token'        # Refresh token endpoint
    end
  end

  # ==========================================
  # 🔐 LEGACY OAUTH ROUTES (Keep for backward compatibility)
  # ==========================================
  
  namespace :api, defaults: { format: :json } do
    namespace :v1 do

resources :updates, only: [:create, :index] do
        member do
          patch :publish
        end
        collection do
          get :manifest
          get :info
          get :check
          post :upload_bundle
        end
      end


      # Google OAuth endpoints - FIXED to point to correct controller
      get 'auth/google_oauth2/init', to: 'omniauth_callbacks#init'
      get 'auth/google_oauth2/callback', to: 'omniauth_callbacks#google_oauth2'
      post 'auth/google_oauth2/callback', to: 'omniauth_callbacks#google_oauth2'
      get 'auth/failure', to: 'omniauth_callbacks#failure'
      
      # Legacy Google login route (maintain compatibility) - keep in sessions
      post :google_login, to: 'sessions#google_login'

      # MPESA API endpoints
      scope :mpesa do
        post 'stk_push', to: 'mpesa#stk_push'
        post 'stk_push_bulk', to: 'mpesa#stk_push_bulk'
        post 'query_status', to: 'mpesa#query_status'
        post 'verify_manual', to: 'mpesa#verify_manual'
        post 'verify_manual_bulk', to: 'mpesa#verify_manual_bulk'
        post 'callback', to: 'mpesa#callback'
        post 'timeout', to: 'mpesa#timeout'
      end
    end
  end

  # ==========================================
  # 🔗 STANDARD OMNIAUTH CALLBACK ROUTES
  # ==========================================
  
  # Standard omniauth routes (Rails will redirect here from Google)
  get '/users/auth/:provider/callback', to: 'api/v1/omniauth_callbacks#google_oauth2'
  
  # Mobile OAuth success page (static)
  get '/oauth/mobile/success', to: proc { |env| 
    [200, { 'Content-Type' => 'text/html' }, [
      '<html><body><h1>Authentication Successful</h1><p>You can close this window.</p></body></html>'
    ]]
  }

  # ==========================================
  # 🗂️ ACTIVE STORAGE ROUTES (Critical - must be early!)
  # ==========================================
  direct :rails_blob_redirect do |blob, options|
    route_for(:rails_service_blob, blob.signed_id, blob.filename, options)
  end

  # ==========================================
  # 📱 API v1 - Main Application Routes
  # ==========================================
  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      # ==========================================
      # 🔐 USER MANAGEMENT & AUTHENTICATION
      # ==========================================
      
      # User profile and management
      get 'users/me', to: 'users#me'
      get 'users', to: 'users#index'
      get 'me', to: 'me#show', defaults: { format: :json }

      resource :me, only: [:show, :update] do
        patch :update_avatar, on: :collection
        delete :destroy_avatar, on: :collection
      end
      get 'users/:user_id/avatar', to: 'avatars#show'
      
      put 'me/avatar', to: 'me#update_avatar'
      delete 'me/avatar', to: 'me#destroy_avatar'

      get 'ping', to: 'status#ping', defaults: { format: :json }
      get 'users/search', to: 'users#search'
      post 'typing_status', to: 'typing_status#create'
      patch 'users/update', to: 'users#update'
      patch 'users/:id/assign_role', to: 'users#assign_role'

      # User scanning analytics & stats
      get 'users/scanning_stats', to: 'users#scanning_stats'
      get 'users/scan_history', to: 'users#scan_history'
      get 'users/performance_metrics', to: 'users#performance_metrics'
      get 'users/dashboard_stats', to: 'users#dashboard_stats'

      # ==========================================
      # 🏢 BUSINESS MANAGEMENT
      # ==========================================
      
      # Business Invites
      resources :invites, only: [:create], defaults: { format: :json } do
        collection do
          post :accept
        end
      end

      # Businesses - UPDATED with full CRUD and categories support
      resources :businesses do
# Business logo routes - nested under businesses
  resource :logo, controller: 'business_logos', only: [:create, :show, :destroy]
  
        member do
          post :add_categories
          delete :remove_category
        end
      end
      
      # Categories routes
      resources :categories, only: [:index, :show]

      # ==========================================
      # 📋 FORM DATA ENDPOINTS
      # ==========================================
      
      namespace :form_data do
        get :areas, to: 'form_data#areas'
        get :agents, to: 'form_data#agents'  
        get :locations, to: 'form_data#locations'
        get :package_form_data, to: 'form_data#package_form_data'
        get :package_states, to: 'form_data#package_states'
        get :delivery_types, to: 'form_data#delivery_types'
        # ADDED: Enhanced form data for new features
        get :package_sizes, to: 'form_data#package_sizes'
        get :pricing_options, to: 'form_data#pricing_options'
      end

      # ==========================================
      # 💰 ENHANCED PRICING SYSTEM
      # ==========================================
      
      resources :prices, only: [:index, :create, :show, :update, :destroy] do
        member do
          patch :update_cost
        end
        collection do
          get :search
          post :bulk_create
          get :matrix
          get :fragile_surcharge
          # UPDATED: Enhanced pricing calculation endpoint
          post :calculate, to: 'prices#calculate'
          get :calculate, to: 'prices#calculate'
        end
      end

      # UPDATED: Comprehensive pricing endpoints for all delivery types
      namespace :pricing do
        # Main calculation endpoint
        post :calculate, to: 'prices#calculate'
        get :calculate, to: 'prices#calculate'
        
        # Delivery type specific pricing
        get :fragile, to: 'prices#fragile_pricing'
        get :home, to: 'prices#home_pricing'
        get :office, to: 'prices#office_pricing'  
        get :collection, to: 'prices#collection_pricing'
        get :agent, to: 'prices#agent_pricing'
        
        # Package size pricing
        get :package_sizes, to: 'prices#package_size_pricing'
        get :size_comparison, to: 'prices#package_size_comparison'
        
        # Comprehensive pricing analysis
        get :matrix, to: 'prices#pricing_matrix'
        get :compare_all, to: 'prices#compare_all_delivery_types'
        get :route_analysis, to: 'prices#route_pricing_analysis'
        
        # Bulk pricing operations
        post :bulk_calculate, to: 'prices#bulk_calculate'
        post :bulk_update, to: 'prices#bulk_update_pricing'
        
        # Pricing validation and verification
        post :validate, to: 'prices#validate_pricing'
        get :verify_consistency, to: 'prices#verify_pricing_consistency'
      end

      # Legacy pricing endpoints (maintain backward compatibility)
      get 'pricing', to: 'packages#calculate_pricing', defaults: { format: :json }
      post 'pricing/calculate', to: 'prices#calculate'
      get 'pricing/matrix', to: 'prices#pricing_matrix'
      get 'pricing/fragile', to: 'prices#fragile_pricing'

      # ==========================================
      # 📦 ENHANCED PACKAGE MANAGEMENT SYSTEM
      # ==========================================
      
      resources :packages, only: [:index, :create, :show, :update, :destroy] do
        member do
          get :validate
          get :qr_code
          get :qr, to: 'packages#qr_code'
          get :thermal_qr_code
          get :qr_comparison
          get :tracking_page
          get :scan_info
          post :pay
          patch :submit
          patch :cancel
          get :timeline
          get :print_history
          # ADDED: Enhanced package management endpoints
          get :delivery_options
          get :size_requirements
          patch :update_delivery_type
          patch :update_package_size
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
          get :qr_codes_batch
          get :thermal_qr_batch
          
          # ADDED: Enhanced package filtering by delivery type and size
          get :fragile_packages
          get :home_deliveries
          get :office_deliveries
          get :collection_packages
          get :agent_deliveries
          get :by_package_size
          get :small_packages
          get :medium_packages
          get :large_packages
          get :requiring_special_handling
          get :delivery_type_breakdown
          get :package_size_analytics
        end
      end

      # ==========================================
      # 🎨 DEDICATED QR CODE ENDPOINTS
      # ==========================================
      
      scope :qr_codes do
        get 'package/:package_code/organic', to: 'packages#qr_code', defaults: { type: 'organic' }
        get 'package/:package_code/thermal', to: 'packages#thermal_qr_code'
        get 'package/:package_code/compare', to: 'packages#qr_comparison'
        
        post :batch_organic, to: 'packages#batch_organic_qr'
        post :batch_thermal, to: 'packages#batch_thermal_qr'
        post :batch_compare, to: 'packages#batch_qr_comparison'
        
        post :test_generation, to: 'qr_codes#test_generation'
        get :generation_stats, to: 'qr_codes#generation_statistics'
        get :thermal_capabilities, to: 'qr_codes#thermal_capabilities'
      end

      # ==========================================
      # 📱 ENHANCED SCANNING SYSTEM
      # ==========================================
      
      scope :scanning do
        post :scan_action, to: 'scanning#scan_action'
        get :package_details, to: 'scanning#package_details'
        post :bulk_scan, to: 'scanning#bulk_scan'
        
        get 'package/:package_code/actions', to: 'scanning#available_actions'
        post 'package/:package_code/validate', to: 'scanning#validate_action'
        get 'package/:package_code/scan_info', to: 'scanning#package_scan_info'
        
        get :scan_statistics, to: 'scanning#scan_statistics'
        get :recent_scans, to: 'scanning#recent_scans'
        get :search_packages, to: 'scanning#search_packages'
        
        post :sync_offline_actions, to: 'scanning#sync_offline_actions'
        get :sync_status, to: 'scanning#sync_status'
        delete :clear_offline_data, to: 'scanning#clear_offline_data'
        
        # ADDED: Enhanced scanning with delivery type awareness
        get :fragile_scan_alerts, to: 'scanning#fragile_package_alerts'
        get :large_package_scan_requirements, to: 'scanning#large_package_requirements'
        get :special_handling_alerts, to: 'scanning#special_handling_alerts'
      end

      # ==========================================
      # 🖨️ ENHANCED PRINTING SYSTEM
      # ==========================================
      
      scope :printing do
        post 'package/:package_code/label', to: 'printing#generate_label'
        post 'package/:package_code/print', to: 'printing#print_label'
        post 'package/:package_code/thermal_label', to: 'printing#generate_thermal_label'
        post 'package/:package_code/thermal_print', to: 'printing#print_thermal_label'
        
        get 'package/:package_code/print_history', to: 'printing#print_history'
        get :print_queue, to: 'printing#print_queue'
        get :printer_status, to: 'printing#printer_status'
        get :thermal_printer_status, to: 'printing#thermal_printer_status'
        
        get :print_settings, to: 'printing#print_settings'
        patch :update_settings, to: 'printing#update_print_settings'
        get :thermal_settings, to: 'printing#thermal_print_settings'
        patch :update_thermal_settings, to: 'printing#update_thermal_settings'
        
        post :bulk_print, to: 'printing#bulk_print'
        post :bulk_thermal_print, to: 'printing#bulk_thermal_print'
        get :bulk_print_status, to: 'printing#bulk_print_status'
        
        post :test_thermal_qr, to: 'printing#test_thermal_qr_printing'
        get :thermal_capabilities, to: 'printing#thermal_printer_capabilities'
        post :validate_thermal_printer, to: 'printing#validate_thermal_printer'
        
        # ADDED: Enhanced printing with delivery type specific formatting
        post 'package/:package_code/fragile_label', to: 'printing#print_fragile_label'
        post 'package/:package_code/collection_label', to: 'printing#print_collection_label'
        post 'package/:package_code/large_package_label', to: 'printing#print_large_package_label'
        get :special_handling_templates, to: 'printing#special_handling_label_templates'
      end

      # ==========================================
      # 📍 ENHANCED TRACKING & EVENTS SYSTEM
      # ==========================================
      
      resources :tracking_events, only: [:index, :show, :create] do
        collection do
          get :recent
          get :by_package
          get :by_user
          get :timeline
          # ADDED: Enhanced tracking for delivery types
          get :fragile_events
          get :collection_events
          get :large_package_events
        end
      end

      scope :tracking do
        get 'package/:package_code', to: 'tracking#package_status'
        get 'package/:package_code/live', to: 'tracking#live_tracking'
        get 'package/:package_code/timeline', to: 'tracking#detailed_timeline'
        get 'package/:package_code/location', to: 'tracking#current_location'
        
        post :batch_status, to: 'tracking#batch_package_status'
        
        # ADDED: Enhanced tracking for special delivery types
        get 'package/:package_code/special_handling_status', to: 'tracking#special_handling_status'
        get 'package/:package_code/delivery_requirements', to: 'tracking#delivery_requirements'
      end

      # ==========================================
      # 🏢 ENHANCED LOCATION & AGENT MANAGEMENT
      # ==========================================
      
      resources :areas, only: [:index, :create, :show, :update, :destroy] do
        member do
          get :packages
          get :routes
          get :agents
          get :scan_activity
          # ADDED: Enhanced area analytics
          get :delivery_type_breakdown
          get :package_size_distribution
          get :pricing_analysis
        end
        collection do
          post :bulk_create
          get :with_stats
          get :pricing_matrix
        end
      end

      resources :locations, only: [:index, :create, :show] do
        member do
          get :areas
          get :package_volume
          # ADDED: Enhanced location analytics
          get :delivery_performance
          get :pricing_comparison
        end
      end

      resources :agents, only: [:index, :create, :show, :update] do
        member do
          get :packages
          get :performance
          get :scan_history
          patch :toggle_active
          # ADDED: Enhanced agent analytics
          get :delivery_type_performance
          get :package_size_handling
          get :special_handling_stats
        end
        collection do
          get :active
          get :by_area
          get :performance_report
          get :fragile_handling_agents
          get :collection_service_agents
        end
      end

      resources :riders, only: [:index, :create, :show, :update] do
        member do
          get :packages
          get :performance
          get :scan_history
          get :route_activity
          patch :toggle_active
          # ADDED: Enhanced rider analytics
          get :delivery_type_stats
          get :special_handling_performance
        end
        collection do
          get :active
          get :by_area
          get :performance_report
          get :fragile_delivery_specialists
        end
      end

      resources :warehouse_staff, only: [:index, :create, :show, :update] do
        member do
          get :packages
          get :performance
          get :scan_history
          get :processing_queue
          patch :toggle_active
          # ADDED: Enhanced warehouse analytics
          get :package_processing_stats
          get :special_handling_queue
        end
        collection do
          get :active
          get :by_location
          get :performance_report
          get :special_handling_staff
        end
      end

      # ==========================================
      # 💬 CONVERSATIONS AND SUPPORT SYSTEM
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
      # 📊 ENHANCED ANALYTICS AND REPORTING
      # ==========================================
      
      namespace :analytics do
        get :overview, to: 'analytics#overview'
        get :packages, to: 'analytics#package_analytics'
        get :revenue, to: 'analytics#revenue_analytics'
        get :performance, to: 'analytics#performance_metrics'
        get :fragile_packages, to: 'analytics#fragile_package_analytics'
        
        # ADDED: Enhanced analytics for new delivery types and package sizes
        get :delivery_type_breakdown, to: 'analytics#delivery_type_breakdown'
        get :package_size_analytics, to: 'analytics#package_size_analytics'
        get :pricing_analytics, to: 'analytics#pricing_analytics'
        get :home_vs_office_comparison, to: 'analytics#home_vs_office_comparison'
        get :collection_service_metrics, to: 'analytics#collection_service_metrics'
        get :special_handling_analytics, to: 'analytics#special_handling_analytics'
        get :cost_efficiency_analysis, to: 'analytics#cost_efficiency_analysis'
        get :delivery_success_rates, to: 'analytics#delivery_success_rates'
        get :customer_preference_trends, to: 'analytics#customer_preference_trends'
      end

      namespace :admin do
        resources :conversations, only: [:index, :show] do
          member do
            patch :assign_to_me
            patch :transfer
            patch 'status', to: 'conversations#update_status'
          end
        end
        
        get 'analytics/scanning', to: 'analytics#scanning_overview'
        get 'analytics/packages', to: 'analytics#package_analytics'
        get 'analytics/performance', to: 'analytics#performance_metrics'
        get 'analytics/fragile_packages', to: 'analytics#fragile_package_analytics'
        
        # ADDED: Enhanced admin analytics
        get 'analytics/delivery_types', to: 'analytics#delivery_type_analytics'
        get 'analytics/pricing_overview', to: 'analytics#pricing_overview'
        get 'analytics/package_sizes', to: 'analytics#package_size_analytics'
        get 'analytics/operational_efficiency', to: 'analytics#operational_efficiency'
        get 'analytics/revenue_optimization', to: 'analytics#revenue_optimization'
      end

      # ==========================================
      # 📄 ENHANCED REPORTS AND EXPORTS
      # ==========================================
      
      scope :reports do
        get 'packages', to: 'reports#packages_report'
        get 'revenue', to: 'reports#revenue_report'
        get 'performance', to: 'reports#performance_report'
        get 'fragile_packages', to: 'reports#fragile_packages_report'
        
        # ADDED: Enhanced reporting for new delivery types
        get 'delivery_types', to: 'reports#delivery_types_report'
        get 'package_sizes', to: 'reports#package_sizes_report'
        get 'pricing_analysis', to: 'reports#pricing_analysis_report'
        get 'home_vs_office', to: 'reports#home_vs_office_report'
        get 'collection_services', to: 'reports#collection_services_report'
        get 'special_handling', to: 'reports#special_handling_report'
        get 'cost_analysis', to: 'reports#cost_analysis_report'
        get 'operational_metrics', to: 'reports#operational_metrics_report'
        
        post 'export/packages', to: 'reports#export_packages'
        post 'export/revenue', to: 'reports#export_revenue'
        post 'export/analytics', to: 'reports#export_analytics'
        post 'export/delivery_types', to: 'reports#export_delivery_types'
        post 'export/pricing_analysis', to: 'reports#export_pricing_analysis'
      end

      # ==========================================
      # 🏥 STATUS & HEALTH ENDPOINTS
      # ==========================================
      
      get 'status', to: 'status#ping'
      get 'health', to: 'status#ping'
      get 'health/pricing', to: 'health#pricing_system_health'
      get 'health/delivery_types', to: 'health#delivery_types_health'
    end
  end

  # ==========================================
  # 🌐 ENHANCED PUBLIC ENDPOINTS
  # ==========================================
  
  scope :public do
    get 'track/:code', to: 'public/tracking#show', as: :public_package_tracking
    get 'track/:code/status', to: 'public/tracking#status'
    get 'track/:code/timeline', to: 'public/tracking#timeline'
    get 'track/:code/qr', to: 'public/tracking#qr_code'
    get 'track/:code/qr/organic', to: 'public/tracking#organic_qr_code'
    get 'track/:code/qr/thermal', to: 'public/tracking#thermal_qr_code'
    
    # ADDED: Public delivery type information
    get 'track/:code/delivery_info', to: 'public/tracking#delivery_information'
    get 'track/:code/special_handling', to: 'public/tracking#special_handling_info'
    
    # Public pricing estimates
    get 'pricing/estimate', to: 'public/pricing#estimate'
    get 'pricing/delivery_types', to: 'public/pricing#delivery_types_info'
    get 'pricing/package_sizes', to: 'public/pricing#package_sizes_info'
  end

  get 'api/v1/track/:code', to: 'api/v1/packages#public_tracking', as: :package_tracking

  # ==========================================
  # 🔗 ENHANCED WEBHOOK ENDPOINTS
  # ==========================================
  
  scope :webhooks do
    post 'payment/success', to: 'webhooks#payment_success'
    post 'payment/failed', to: 'webhooks#payment_failed'
    post 'tracking/update', to: 'webhooks#tracking_update'
    post 'delivery/notification', to: 'webhooks#delivery_notification'
    post 'printer/status', to: 'webhooks#printer_status_update'
    post 'printer/error', to: 'webhooks#printer_error'
    post 'thermal_printer/status', to: 'webhooks#thermal_printer_status_update'
    post 'thermal_printer/error', to: 'webhooks#thermal_printer_error'
    post 'scan/completed', to: 'webhooks#scan_completed'
    post 'bulk_scan/completed', to: 'webhooks#bulk_scan_completed'
    post 'qr_generation/completed', to: 'webhooks#qr_generation_completed'
    post 'thermal_qr/generated', to: 'webhooks#thermal_qr_generated'
    post 'auth/google/success', to: 'webhooks#google_auth_success'
    post 'auth/google/failure', to: 'webhooks#google_auth_failure'
    
    # ADDED: Enhanced webhooks for delivery types
    post 'fragile/special_handling_alert', to: 'webhooks#fragile_handling_alert'
    post 'collection/pickup_scheduled', to: 'webhooks#collection_pickup_scheduled'
    post 'large_package/handling_alert', to: 'webhooks#large_package_handling_alert'
    post 'pricing/update_notification', to: 'webhooks#pricing_update_notification'
  end

  # ==========================================
  # 🏥 ENHANCED HEALTH CHECK & STATUS
  # ==========================================
  
  get "up" => "rails/health#show", as: :rails_health_check
  
  get "health/db" => "health#database", as: :database_health_check
  get "health/redis" => "health#redis", as: :redis_health_check if defined?(Redis)
  get "health/jobs" => "health#background_jobs", as: :jobs_health_check
  get "health/scanning" => "health#scanning_system", as: :scanning_health_check
  get "health/qr_generation" => "health#qr_generation_system", as: :qr_generation_health_check
  get "health/thermal_printing" => "health#thermal_printing_system", as: :thermal_printing_health_check
  get "health/google_oauth" => "health#google_oauth_system", as: :google_oauth_health_check
  get "health/pricing_system" => "health#pricing_system", as: :pricing_system_health_check
  get "health/delivery_types" => "health#delivery_types_system", as: :delivery_types_health_check
  
  # ==========================================
  # 📱 PROGRESSIVE WEB APP SUPPORT
  # ==========================================
  
  get '/manifest.json', to: 'pwa#manifest'
  get '/sw.js', to: 'pwa#service_worker'
  get '/offline', to: 'pwa#offline'

  # ==========================================
  # 📚 ENHANCED DOCUMENTATION
  # ==========================================
  
  get '/docs', to: 'documentation#index'
  get '/api/docs', to: 'documentation#api_docs'
  get '/docs/qr_codes', to: 'documentation#qr_code_docs'
  get '/docs/google_auth', to: 'documentation#google_auth_docs'
  get '/docs/pricing', to: 'documentation#pricing_docs'
  get '/docs/delivery_types', to: 'documentation#delivery_types_docs'
  get '/docs/package_sizes', to: 'documentation#package_sizes_docs'

  # ==========================================
  # 🔀 CATCH-ALL AND REDIRECTS
  # ==========================================
  
  # FIXED: Use a conditional root that redirects unauthenticated users to sign in
  # but allows API access to work normally
  root to: 'sessions#redirect_root'
  
  # More specific catch-all that doesn't interfere with Active Storage
  constraints(->(request) { 
    !request.path.start_with?('/rails/active_storage/') &&
    !request.path.start_with?('/assets/') &&
    !request.path.start_with?('/packs/') &&
    !request.path.include?('favicon')
  }) do
    match '*unmatched', to: 'application#route_not_found', via: :all
  end
end