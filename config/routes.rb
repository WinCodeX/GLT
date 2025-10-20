require 'sidekiq/web'

Rails.application.routes.draw do

  # ==========================================
  # 🔌 ACTIONCABLE MOUNT - CRITICAL FIX
  # ==========================================
  mount ActionCable.server => '/cable'

  # ==========================================
  # 💼 SIDEKIQ WEB INTERFACE
  # ==========================================
  
  if Rails.env.development?
    mount Sidekiq::Web => '/sidekiq'
  else
    # In production, protect with authentication
    Sidekiq::Web.use Rack::Auth::Basic do |username, password|
      username == ENV['SIDEKIQ_USERNAME'] && password == ENV['SIDEKIQ_PASSWORD']
    end
    mount Sidekiq::Web => '/admin/sidekiq'
  end

  # ==========================================
  # 🔐 WEB AUTHENTICATION (Simple Sign In)
  # ==========================================
  
  namespace :admin do
  root 'updates#index'


resources :sms_messaging, only: [:index, :create]

  # Updates (existing)
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

  # Notifications Web Interface - FIXED
  resources :notifications, only: [:index, :show, :new, :create, :destroy] do
    member do
      patch :mark_as_read
      patch :mark_as_unread
    end

    collection do
      get :broadcast_form
      post :broadcast
      get :stats
    end
  end

  # Cable Monitoring Web Interface - FIXED
  # Changed from singular resource to custom routes
  get 'cable', to: 'cable_monitoring#index', as: 'cable'
  get 'cable/connections', to: 'cable_monitoring#connections', as: 'cable_connections'
  get 'cable/subscriptions', to: 'cable_monitoring#subscriptions', as: 'cable_subscriptions'
  get 'cable/stats', to: 'cable_monitoring#stats', as: 'cable_stats'
  post 'cable/test_broadcast', to: 'cable_monitoring#test_broadcast', as: 'test_broadcast_cable'

  # Conversations Web Interface - FIXED
  resources :conversations, only: [:index, :show] do
    member do
      patch :assign_to_me
      patch :update_status, as: 'update_status_for'
    end

    collection do
      get :test
      post :test_message
    end
  end
end

# Web Authentication Routes
get '/dashboard', to: 'sessions#dashboard', as: :dashboard
get '/sign_in', to: 'sessions#new', as: :sign_in
post '/sign_in', to: 'sessions#create'
delete '/sign_out', to: 'sessions#destroy', as: :sign_out
get '/logout', to: 'sessions#destroy'

  # ==========================================
  # 🔐 AUTHENTICATION (Devise)
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
  # 🔐 EXPO-AUTH-SESSION OAUTH ROUTES
  # ==========================================
  
  namespace :api do
    namespace :auth do
      get 'authorize', to: 'oauth#authorize'
      get 'callback', to: 'oauth#callback'
      post 'token', to: 'oauth#token_exchange'
      get 'session', to: 'oauth#session'
      post 'logout', to: 'oauth#logout'
      post 'refresh', to: 'oauth#refresh_token'
    end
  end

  # ==========================================
  # 🔗 API ROUTES
  # ==========================================
  
  namespace :api, defaults: { format: :json } do
    namespace :v1 do

      # ==========================================
      #  👨‍💼 Staff Routes
      # ==========================================

       namespace :staff do
        # Dashboard
        get 'dashboard/stats', to: 'staff#dashboard_stats'
        
        # Packages
        get 'packages', to: 'staff#packages'
        get 'packages/:id', to: 'staff#show_package'
        get 'packages/:id/track', to: 'staff#track_package'
        post 'packages/:id/reject', to: 'staff#reject_package'
        
        # Scan Events
        get 'scan_events', to: 'staff#scan_events'
        post 'scan_events', to: 'staff#create_scan_event'
        
        # Activities
        get 'activities', to: 'staff#activities'
        
        # Rejections
        get 'rejections', to: 'staff#rejections'
      end




       # ==========================================
      # 👛 Wallet Routes
      # ==========================================

       resource :wallet, only: [] do
        get '/', to: 'wallets#show', as: :show
        get :transactions
        get :withdrawals
        get :summary
        post 'topup', to: 'wallets#topup'
        post :withdraw
        post 'withdrawals/:id/cancel', to: 'wallets#cancel_withdrawal', as: :cancel_withdrawal
      end

       # ==========================================
      # 🏍 Rider Routes
      # ==========================================
      resources :riders, only: [] do
        collection do
          get :active_deliveries
          post :location
          post :offline
          get :stats
          get :areas
          
          # Reports
          post 'reports', to: 'riders#create_report'
          get 'reports', to: 'riders#reports'
        end
      end


      # ==========================================
      #  🆘️ Support Routes
      # ==========================================

      scope :support, controller: :support do
        # Dashboard and overview
        get :dashboard, to: 'support#dashboard'
        get :stats, to: 'support#stats'
        
        # Ticket management
        get :tickets, to: 'support#tickets'
        get :my_tickets, to: 'support#my_tickets'
        
        # Agent management
        get :agents, to: 'support#agents'
        
        # Bulk operations
        post :bulk_actions, to: 'support#bulk_actions'
        
        # Individual ticket actions
        scope :tickets do
          post ':id/assign', to: 'support#assign_ticket'
          post ':id/escalate', to: 'support#escalate_ticket'
          post ':id/note', to: 'support#add_note'
          patch ':id/priority', to: 'support#update_priority'
        end
      end

      # ==========================================
      # 📱 APP UPDATES
      # ==========================================
      
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

      # ==========================================
      # 📇 CONTACTS
      # ==========================================
      
      resources :contacts, only: [] do
        collection do
          post :check_registered
          get :my_contacts
          post :sync
        end
      end

      # ==========================================
      # 🔐 GOOGLE OAUTH
      # ==========================================
      
      get 'auth/google_oauth2/init', to: 'omniauth_callbacks#init'
      get 'auth/google_oauth2/callback', to: 'omniauth_callbacks#google_oauth2'
      post 'auth/google_oauth2/callback', to: 'omniauth_callbacks#google_oauth2'
      get 'auth/failure', to: 'omniauth_callbacks#failure'
      post :google_login, to: 'sessions#google_login'

      # ==========================================
      # 💳 MPESA API
      # ==========================================
      
         scope :mpesa do
  # Authenticated endpoints
  post 'stk_push', to: 'mpesa#stk_push'
  post 'stk_push_bulk', to: 'mpesa#stk_push_bulk'
  post 'query_status', to: 'mpesa#query_status'
  post 'verify_manual', to: 'mpesa#verify_manual'
  post 'verify_manual_bulk', to: 'mpesa#verify_manual_bulk'
  post 'topup', to: 'mpesa#topup'
  post 'topup_manual', to: 'mpesa#topup_manual'
  
  # Callback endpoints (no authentication)
  post 'callback', to: 'mpesa#callback'                    # Package payments callback
  post 'wallet_callback', to: 'mpesa#wallet_callback'      # Wallet topup callback (FIXED)
  post 'timeout', to: 'mpesa#timeout'
  post 'verify_callback', to: 'mpesa#verify_callback'
  post 'verify_timeout', to: 'mpesa#verify_timeout'
end
      
      # ==========================================
      # 📄 TERMS AND CONDITIONS
      # ==========================================
      
      resources :terms do
        collection do
          get :current
        end
      end

      get 'current_terms/:type', to: 'terms#current', defaults: { type: 'terms_of_service' }
      get 'current_terms', to: 'terms#current', defaults: { type: 'terms_of_service' }

      # ==========================================
      # 👤 USER MANAGEMENT
      # ==========================================
      
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

      get 'users/scanning_stats', to: 'users#scanning_stats'
      get 'users/scan_history', to: 'users#scan_history'
      get 'users/performance_metrics', to: 'users#performance_metrics'
      get 'users/dashboard_stats', to: 'users#dashboard_stats'

      # ==========================================
      # 🏢 BUSINESS MANAGEMENT
      # ==========================================
      
      resources :invites, only: [:create], defaults: { format: :json } do
        collection do
          post :accept
        end
      end

      resources :businesses do
        resource :logo, controller: 'business_logos', only: [:create, :show, :destroy]
        
        member do
          post :add_categories
          delete :remove_category
          get :staff
          get :activities
          get 'staff/:staff_id/activities', to: 'businesses#staff_activities'
          
          # NEW: Analytics endpoints
          get 'analytics/packages-comparison', to: 'businesses#packages_comparison'
          get 'analytics/best-locations', to: 'businesses#best_locations'
        end
      end
      
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
        get :package_sizes, to: 'form_data#package_sizes'
        get :pricing_options, to: 'form_data#pricing_options'
      end

      # ==========================================
      # 💰 PRICING SYSTEM
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
          post :calculate, to: 'prices#calculate'
          get :calculate, to: 'prices#calculate'
        end
      end

      namespace :pricing do
        post :calculate, to: 'prices#calculate'
        get :calculate, to: 'prices#calculate'
        
        get :fragile, to: 'prices#fragile_pricing'
        get :home, to: 'prices#home_pricing'
        get :office, to: 'prices#office_pricing'  
        get :collection, to: 'prices#collection_pricing'
        get :agent, to: 'prices#agent_pricing'
        
        get :package_sizes, to: 'prices#package_size_pricing'
        get :size_comparison, to: 'prices#package_size_comparison'
        
        get :matrix, to: 'prices#pricing_matrix'
        get :compare_all, to: 'prices#compare_all_delivery_types'
        get :route_analysis, to: 'prices#route_pricing_analysis'
        
        post :bulk_calculate, to: 'prices#bulk_calculate'
        post :bulk_update, to: 'prices#bulk_update_pricing'
        
        post :validate, to: 'prices#validate_pricing'
        get :verify_consistency, to: 'prices#verify_pricing_consistency'
      end

      get 'pricing', to: 'packages#calculate_pricing', defaults: { format: :json }
      post 'pricing/calculate', to: 'prices#calculate'
      get 'pricing/matrix', to: 'prices#pricing_matrix'
      get 'pricing/fragile', to: 'prices#fragile_pricing'

      # ==========================================
      # 📦 PACKAGE MANAGEMENT
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
          get :delivery_options
          get :size_requirements
          patch :update_delivery_type
          patch :update_package_size
          post :resubmit
          post :reject
          get :resubmission_info
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
          get :expired_summary
          post :force_expiry_check
        end
      end

      # ==========================================
      # 📬 NOTIFICATIONS
      # ==========================================
      
      resources :notifications, only: [:index, :show, :destroy] do
        member do
          patch :mark_as_read
        end
        
        collection do
           patch :mark_all_as_read
           post :mark_visible_as_read  # NEW ROUTE
           get :unread_count
           get :summary
          end
        end

      resources :push_tokens, only: [:create, :destroy], param: :token

      # ==========================================
      # 🎨 QR CODE ENDPOINTS
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
      # 📱 SCANNING SYSTEM
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
        
        get :fragile_scan_alerts, to: 'scanning#fragile_package_alerts'
        get :large_package_scan_requirements, to: 'scanning#large_package_requirements'
        get :special_handling_alerts, to: 'scanning#special_handling_alerts'
      end

      # ==========================================
      # 🖨️ PRINTING SYSTEM
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
        
        post 'package/:package_code/fragile_label', to: 'printing#print_fragile_label'
        post 'package/:package_code/collection_label', to: 'printing#print_collection_label'
        post 'package/:package_code/large_package_label', to: 'printing#print_large_package_label'
        get :special_handling_templates, to: 'printing#special_handling_label_templates'
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
        
        get 'package/:package_code/special_handling_status', to: 'tracking#special_handling_status'
        get 'package/:package_code/delivery_requirements', to: 'tracking#delivery_requirements'
      end

      # ==========================================
      # 🏢 LOCATION & AGENT MANAGEMENT
      # ==========================================
      
      resources :areas, only: [:index, :create, :show, :update, :destroy] do
        member do
          get :packages
          get :routes
          get :agents
          get :scan_activity
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
      # 💬 ENHANCED CONVERSATIONS
      # ==========================================
      
      resources :conversations, only: [:index, :show] do
        member do
          patch :close
          patch :reopen
          patch :assign
          patch :accept_ticket
          post :send_message
        end
        
        resources :messages, only: [:index, :create] do
          collection do
            patch :mark_read
          end
        end
        
        collection do
          post :support_ticket, to: 'conversations#create_support_ticket'
          get :active_support, to: 'conversations#active_support'
          get :package_support
        end
      end

      # ==========================================
      # 📊 ANALYTICS
      # ==========================================
      
      namespace :analytics do
        get :overview, to: 'analytics#overview'
        get :packages, to: 'analytics#package_analytics'
        get :revenue, to: 'analytics#revenue_analytics'
        get :performance, to: 'analytics#performance_metrics'
        get :fragile_packages, to: 'analytics#fragile_package_analytics'
        
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

      # ==========================================
      # 🔐 ADMIN ROUTES
      # ==========================================
      
      namespace :admin do
        # Notifications API
        resources :notifications, only: [:index, :show, :create, :destroy] do
          member do
            patch :mark_as_read
            patch :mark_as_unread
            post :resend_push
          end
          
          collection do
            get :stats
            post :broadcast
          end
        end
        
        # Conversations API (Fixed)
        resources :conversations, only: [:index, :show] do
          member do
            patch :assign_to_me
            patch :transfer
            patch :update_status, path: 'status'
            post :send_message
          end
        end
        
        # Users API
        resources :users, only: [] do
          collection do
            get :search
          end
        end
      end

      # ==========================================
      # 📄 REPORTS
      # ==========================================
      
      scope :reports do
        get 'packages', to: 'reports#packages_report'
        get 'revenue', to: 'reports#revenue_report'
        get 'performance', to: 'reports#performance_report'
        get 'fragile_packages', to: 'reports#fragile_packages_report'
        
        get 'delivery_types', to: 'reports#delivery_types_report'
        get 'package_sizes', to: 'reports#package_sizes_report'
        get 'pricing_analysis', to: 'reports#pricing_analysis_report'
        get 'home_vs_office', to: 'reports#home_vs_office_report'
        get 'collection_services', to: 'reports#collection_services_report'
        get 'special_handling', to: 'reports#special_handling_report'
        get 'cost_analysis', to: 'reports#cost_analysis_report'
        get 'operational_metrics', to: 'reports#operational_metrics_report'
        get 'notifications', to: 'reports#notifications_report'
        
        post 'export/packages', to: 'reports#export_packages'
        post 'export/revenue', to: 'reports#export_revenue'
        post 'export/analytics', to: 'reports#export_analytics'
        post 'export/delivery_types', to: 'reports#export_delivery_types'
        post 'export/pricing_analysis', to: 'reports#export_pricing_analysis'
        post 'export/notifications', to: 'reports#export_notifications'
      end

      # ==========================================
      # 🏥 STATUS & HEALTH
      # ==========================================
      
      get 'status', to: 'status#ping'
      get 'health', to: 'status#ping'
      get 'health/pricing', to: 'health#pricing_system_health'
      get 'health/delivery_types', to: 'health#delivery_types_health'
      get 'health/notifications', to: 'health#notifications_health'
    end
  end

# ==========================================
# 🌐 PUBLIC ENDPOINTS
# ==========================================

namespace :public do
  # Landing page
  get 'home', to: 'home#index', as: 'home'

  # Tracking search page
  get 'track', to: 'tracking#index', as: 'tracking_index'

  # Agent area endpoint (REQUIRED for automatic pricing)
  get 'agents/:id/area', to: 'agents#area', as: 'agent_area'

  # M-Pesa payment endpoints for public packages
  # FIXED: Remove nested namespace since controller is Public::MpesaController (not Public::Mpesa::MpesaController)
  post 'mpesa/initiate_payment', to: 'mpesa#initiate_payment', as: 'mpesa_initiate_payment'
  get 'mpesa/check_payment_status', to: 'mpesa#check_payment_status', as: 'mpesa_check_payment_status'
  post 'mpesa/verify_manual', to: 'mpesa#verify_manual', as: 'mpesa_verify_manual'
  post 'mpesa/callback', to: 'mpesa#callback', as: 'mpesa_callback'

  # Package routes
  resources :packages, only: [:new, :create] do
    collection do
      # These need explicit names for the path helpers to work
      post 'calculate_pricing', as: 'calculate_pricing'

      # Delivery type specific routes
      get 'fragile', action: :new, defaults: { delivery_type: 'fragile' }, as: 'fragile'
      get 'home', action: :new, defaults: { delivery_type: 'home' }, as: 'home_delivery'
      get 'doorstep', action: :new, defaults: { delivery_type: 'doorstep' }, as: 'doorstep'
      get 'office', action: :new, defaults: { delivery_type: 'office' }, as: 'office'
      get 'agent', action: :new, defaults: { delivery_type: 'agent' }, as: 'agent'
      get 'collection', action: :new, defaults: { delivery_type: 'collection' }, as: 'collection'
    end
  end

  # Shorter alias for package creation
  get 'package', to: 'packages#new', as: 'package_new'

  # Tracking routes
  scope :track do
    get ':code', to: 'tracking#show', as: 'package_tracking'
    get ':code/status', to: 'tracking#status'
    get ':code/timeline', to: 'tracking#timeline'
    get ':code/qr', to: 'tracking#qr_code'
    get ':code/qr/organic', to: 'tracking#organic_qr_code'
    get ':code/qr/thermal', to: 'tracking#thermal_qr_code'
    get ':code/delivery_info', to: 'tracking#delivery_information'
    get ':code/special_handling', to: 'tracking#special_handling_info'
  end

  # Pricing routes
  scope :pricing do
    get 'estimate', to: 'pricing#estimate'
    get 'delivery_types', to: 'pricing#delivery_types_info'
    get 'package_sizes', to: 'pricing#package_sizes_info'
  end
end

# ==========================================
# 🔗 API V1 TRACKING REDIRECT
# ==========================================

# Redirect API tracking requests to public tracking page
namespace :api do
  namespace :v1 do
    # This route redirects to the public tracking view
    get 'track/:code', to: redirect { |params, _request| "/public/track/#{params[:code]}" }
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
    post 'thermal_printer/status', to: 'webhooks#thermal_printer_status_update'
    post 'thermal_printer/error', to: 'webhooks#thermal_printer_error'
    post 'scan/completed', to: 'webhooks#scan_completed'
    post 'bulk_scan/completed', to: 'webhooks#bulk_scan_completed'
    post 'qr_generation/completed', to: 'webhooks#qr_generation_completed'
    post 'thermal_qr/generated', to: 'webhooks#thermal_qr_generated'
    post 'auth/google/success', to: 'webhooks#google_auth_success'
    post 'auth/google/failure', to: 'webhooks#google_auth_failure'
    
    post 'fragile/special_handling_alert', to: 'webhooks#fragile_handling_alert'
    post 'collection/pickup_scheduled', to: 'webhooks#collection_pickup_scheduled'
    post 'large_package/handling_alert', to: 'webhooks#large_package_handling_alert'
    post 'pricing/update_notification', to: 'webhooks#pricing_update_notification'
    post 'notifications/delivery_status', to: 'webhooks#notification_delivery_status'
  end

  # ==========================================
  # 🏥 HEALTH CHECKS
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
  get "health/notifications" => "health#notifications_system", as: :notifications_health_check
  
  # ==========================================
  # 📱 PWA SUPPORT
  # ==========================================
  
  get '/manifest.json', to: 'pwa#manifest'
  get '/sw.js', to: 'pwa#service_worker'
  get '/offline', to: 'pwa#offline'

  # ==========================================
  # 📚 DOCUMENTATION
  # ==========================================
  
  get '/docs', to: 'documentation#index'
  get '/api/docs', to: 'documentation#api_docs'
  get '/docs/qr_codes', to: 'documentation#qr_code_docs'
  get '/docs/google_auth', to: 'documentation#google_auth_docs'
  get '/docs/pricing', to: 'documentation#pricing_docs'
  get '/docs/delivery_types', to: 'documentation#delivery_types_docs'
  get '/docs/package_sizes', to: 'documentation#package_sizes_docs'
  get '/docs/notifications', to: 'documentation#notifications_docs'

  # ==========================================
  # 🔀 ROOT AND CATCH-ALL
  # ==========================================
  
  root to: 'public/home#index'
  
  constraints(->(request) { 
  !request.path.start_with?('/rails/active_storage/') &&
  !request.path.start_with?('/assets/') &&
  !request.path.start_with?('/packs/') &&
  !request.path.start_with?('/images/') &&      # For logo
  !request.path.match?(/\.ico$/) &&             # For favicon.ico
  !request.path.match?(/favicon/) &&            # For all favicon files
  !request.path.match?(/apple-touch-icon/) &&   # For iOS icons
  !request.path.match?(/android-chrome/) &&     # For Android icons
  !request.path.match?(/site\.webmanifest/)     # For PWA manifest
}) do
  match '*unmatched', to: 'application#route_not_found', via: :all
 end
end