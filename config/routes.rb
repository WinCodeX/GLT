# config/routes.rb - Enhanced with Google OAuth support
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
      registrations: 'api/v1/registrations',
      omniauth_callbacks: 'api/v1/omniauth_callbacks'
    }
  
  devise_scope :user do
    post 'api/v1/signup', to: 'api/v1/registrations#create'
  end

  # ==========================================
  # 🔐 GOOGLE OAUTH ROUTES (New)
  # ==========================================
  
  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      # Google OAuth endpoints
      namespace :auth do
        # Step 1: Initialize OAuth flow (for web)
        get 'google_oauth2/init', to: 'sessions#google_oauth_init'
        
        # Step 2: OAuth callback (for web)
        get 'google_oauth2/callback', to: 'sessions#google_oauth_callback'
        post 'google_oauth2/callback', to: 'sessions#google_oauth_callback'
        
        # Step 3: Token validation (for mobile)
        post 'google/login', to: 'sessions#google_login'
        post 'google_login', to: 'sessions#google_login'
        
        # OAuth failure handler
        get 'failure', to: 'sessions#oauth_failure'
        post 'failure', to: 'sessions#oauth_failure'
      end
      
      # Legacy Google login route (maintain compatibility)
      post :google_login, to: 'sessions#google_login'
    end
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
      put 'me/avatar', to: 'me#update_avatar'
      delete 'me/avatar', to: 'me#destroy_avatar'  # ✅ Added missing delete route
      get 'ping', to: 'status#ping', defaults: { format: :json }
      get 'users/search', to: 'users#search'
      post 'typing_status', to: 'typing_status#create'
      patch 'users/update', to: 'users#update'
      patch 'users/:id/assign_role', to: 'users#assign_role'

      # 📊 USER SCANNING ANALYTICS & STATS - Fixed routing
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

      # Businesses
      resources :businesses, only: [:create, :index, :show], defaults: { format: :json }

      # ==========================================
      # 📦 PACKAGE MANAGEMENT & SCANNING SYSTEM
      # ==========================================
      
      # 📋 FORM DATA ENDPOINTS (For Package Creation & Editing)
      namespace :form_data do
        get :areas, to: 'form_data#areas'
        get :agents, to: 'form_data#agents'  
        get :locations, to: 'form_data#locations'
        get :package_form_data, to: 'form_data#package_form_data'
        get :package_states, to: 'form_data#package_states'
        get :delivery_types, to: 'form_data#delivery_types'
      end

      # Core Package Resources - ENHANCED WITH QR ENDPOINTS
      resources :packages, only: [:index, :create, :show, :update, :destroy] do
        member do
          # 📋 Package Information & Validation
          get :validate          # Validate package by code
          
          # 🎨 QR CODE GENERATION ENDPOINTS - ENHANCED
          get :qr_code          # Generate QR code (supports ?type=organic|thermal)
          get :thermal_qr_code  # 🖨️ NEW: Generate thermal-optimized QR code
          get :qr_comparison    # 🔍 NEW: Compare organic vs thermal QR codes
          
          get :tracking_page    # Full tracking information
          get :scan_info        # Package info for scanning (basic details + actions)
          
          # 💳 Payment & State Management
          post :pay             # Process payment
          patch :submit         # Submit for delivery
          patch :cancel         # Cancel package
          
          # 📊 Package Analytics
          get :timeline         # Detailed tracking timeline
          get :print_history    # Print logs for this package
        end
        
        collection do
          # 🔍 Search & Discovery
          get :search           # Search packages by code
          get :advanced_search  # Advanced search with filters
          
          # 📊 Analytics & Reports
          get :stats           # Package statistics
          get :analytics       # Detailed analytics for role-based users
          
          # 💰 Pricing & Cost Calculation
          get :pricing         # Calculate package pricing
          post :calculate_cost # Calculate cost for package parameters
          
          # 📱 Bulk Operations
          post :bulk_create    # Create multiple packages
          patch :bulk_update   # Update multiple packages
          
          # 🎨 QR CODE COLLECTION ENDPOINTS - NEW
          get :qr_codes_batch  # 🆕 Generate QR codes for multiple packages
          get :thermal_qr_batch # 🆕 Generate thermal QR codes for multiple packages
        end
      end

      # ==========================================
      # 🎨 DEDICATED QR CODE ENDPOINTS - NEW SECTION
      # ==========================================
      
      scope :qr_codes do
        # Single package QR generation
        get 'package/:package_code/organic', to: 'packages#qr_code', defaults: { type: 'organic' }
        get 'package/:package_code/thermal', to: 'packages#thermal_qr_code'
        get 'package/:package_code/compare', to: 'packages#qr_comparison'
        
        # Batch QR generation
        post :batch_organic, to: 'packages#batch_organic_qr'
        post :batch_thermal, to: 'packages#batch_thermal_qr'
        post :batch_compare, to: 'packages#batch_qr_comparison'
        
        # QR testing and debugging
        post :test_generation, to: 'qr_codes#test_generation'
        get :generation_stats, to: 'qr_codes#generation_statistics'
        get :thermal_capabilities, to: 'qr_codes#thermal_capabilities'
      end

      # ==========================================
      # 📱 SCANNING SYSTEM (Core Functionality)
      # ==========================================
      
      # Main Scanning Endpoints
      scope :scanning do
        # 🎯 Primary Scanning Actions
        post :scan_action, to: 'scanning#scan_action'              # Main scanning endpoint
        get :package_details, to: 'scanning#package_details'       # Get package + available actions
        post :bulk_scan, to: 'scanning#bulk_scan'                  # Bulk scanning operations
        
        # 📋 Action Validation & Info
        get 'package/:package_code/actions', to: 'scanning#available_actions'
        post 'package/:package_code/validate', to: 'scanning#validate_action'
        get 'package/:package_code/scan_info', to: 'scanning#package_scan_info'
        
        # 📊 Scanning Analytics
        get :scan_statistics, to: 'scanning#scan_statistics'
        get :recent_scans, to: 'scanning#recent_scans'
        
        # 🔍 Package Search for Scanning
        get :search_packages, to: 'scanning#search_packages'
        
        # 🔄 Offline Sync Support
        post :sync_offline_actions, to: 'scanning#sync_offline_actions'
        get :sync_status, to: 'scanning#sync_status'
        delete :clear_offline_data, to: 'scanning#clear_offline_data'
      end

      # Enhanced Package Search for Scanning
      get 'packages/search', to: 'packages#search'

      # ==========================================
      # 🖨️ PRINTING SYSTEM - ENHANCED WITH THERMAL QR
      # ==========================================
      
      scope :printing do
        # 📄 Label Generation - ENHANCED
        post 'package/:package_code/label', to: 'printing#generate_label'
        post 'package/:package_code/print', to: 'printing#print_label'
        post 'package/:package_code/thermal_label', to: 'printing#generate_thermal_label'  # 🖨️ NEW
        post 'package/:package_code/thermal_print', to: 'printing#print_thermal_label'    # 🖨️ NEW
        
        # 📊 Print Management
        get 'package/:package_code/print_history', to: 'printing#print_history'
        get :print_queue, to: 'printing#print_queue'
        get :printer_status, to: 'printing#printer_status'
        get :thermal_printer_status, to: 'printing#thermal_printer_status'  # 🖨️ NEW
        
        # ⚙️ Print Configuration
        get :print_settings, to: 'printing#print_settings'
        patch :update_settings, to: 'printing#update_print_settings'
        get :thermal_settings, to: 'printing#thermal_print_settings'        # 🖨️ NEW
        patch :update_thermal_settings, to: 'printing#update_thermal_settings' # 🖨️ NEW
        
        # 📱 Bulk Printing - ENHANCED
        post :bulk_print, to: 'printing#bulk_print'
        post :bulk_thermal_print, to: 'printing#bulk_thermal_print'          # 🖨️ NEW
        get :bulk_print_status, to: 'printing#bulk_print_status'
        
        # 🔧 Thermal Printer Testing - NEW
        post :test_thermal_qr, to: 'printing#test_thermal_qr_printing'
        get :thermal_capabilities, to: 'printing#thermal_printer_capabilities'
        post :validate_thermal_printer, to: 'printing#validate_thermal_printer'
      end

      # ==========================================
      # 📍 TRACKING & EVENTS SYSTEM
      # ==========================================
      
      # Package Tracking Events
      resources :tracking_events, only: [:index, :show, :create] do
        collection do
          get :recent           # Recent tracking events
          get :by_package      # Events for specific package
          get :by_user         # Events by specific user
          get :timeline        # Timeline view
        end
      end

      # Real-time Tracking
      scope :tracking do
        get 'package/:package_code', to: 'tracking#package_status'
        get 'package/:package_code/live', to: 'tracking#live_tracking'
        get 'package/:package_code/timeline', to: 'tracking#detailed_timeline'
        get 'package/:package_code/location', to: 'tracking#current_location'
        
        # Batch tracking
        post :batch_status, to: 'tracking#batch_package_status'
      end

      # ==========================================
      # 🏢 LOCATION & AGENT MANAGEMENT
      # ==========================================
      
      # Areas - Enhanced with package management and route analytics
      resources :areas, only: [:index, :create, :show, :update, :destroy] do
        member do
          get :packages         # Get packages for this area
          get :routes          # Get route statistics
          get :agents          # Get agents in this area
          get :scan_activity   # Scanning activity in this area
        end
        collection do
          post :bulk_create     # Create multiple areas at once
          get :with_stats      # Areas with package statistics
        end
      end

      # Locations - Keep existing functionality + analytics
      resources :locations, only: [:index, :create, :show] do
        member do
          get :areas           # Areas in this location
          get :package_volume  # Package volume analytics
        end
      end

      # Agents - Enhanced with performance tracking
      resources :agents, only: [:index, :create, :show, :update] do
        member do
          get :packages        # Packages handled by this agent
          get :performance     # Agent performance metrics
          get :scan_history    # Agent's scanning history
          patch :toggle_active # Activate/deactivate agent
        end
        collection do
          get :active          # Only active agents
          get :by_area         # Agents filtered by area
          get :performance_report # Performance report for all agents
        end
      end

      # Riders - Enhanced with scanning activity
      resources :riders, only: [:index, :create, :show, :update] do
        member do
          get :packages        # Packages handled by this rider
          get :performance     # Rider performance metrics
          get :scan_history    # Rider's scanning history
          get :route_activity  # Current route activity
          patch :toggle_active # Activate/deactivate rider
        end
        collection do
          get :active          # Only active riders
          get :by_area         # Riders filtered by area
          get :performance_report # Performance report for all riders
        end
      end

      # Warehouse Staff - New resource for warehouse management
      resources :warehouse_staff, only: [:index, :create, :show, :update] do
        member do
          get :packages        # Packages processed by this staff
          get :performance     # Warehouse staff performance metrics
          get :scan_history    # Staff's scanning history
          get :processing_queue # Current processing queue
          patch :toggle_active # Activate/deactivate staff
        end
        collection do
          get :active          # Only active warehouse staff
          get :by_location     # Staff filtered by location
          get :performance_report # Performance report for warehouse
        end
      end

      # ==========================================
      # 💰 PRICING SYSTEM
      # ==========================================
      
      # Prices - Enhanced pricing calculation
      resources :prices, only: [:index, :create, :show, :update, :destroy] do
        member do
          patch :update_cost   # Update pricing cost
        end
        collection do
          get :calculate        # Alternative pricing calculation endpoint
          get :search          # Search prices by criteria
          post :bulk_create    # Create multiple price rules
          get :matrix          # Pricing matrix view
          get :fragile_surcharge # Get fragile handling surcharges
        end
      end

      # 🔥 DEDICATED PRICING ENDPOINTS (matches React Native helper expectations)
      get 'pricing', to: 'packages#calculate_pricing', defaults: { format: :json }
      post 'pricing/calculate', to: 'packages#calculate_pricing'
      get 'pricing/matrix', to: 'prices#pricing_matrix'
      get 'pricing/fragile', to: 'prices#fragile_pricing'

      # ==========================================
      # 💬 CONVERSATIONS AND SUPPORT SYSTEM
      # ==========================================
      
      resources :conversations, only: [:index, :show] do
        member do
          patch :close
          patch :reopen
          patch :assign        # Assign conversation to agent
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
      get 'conversations/package_support', to: 'conversations#package_support'

      # Admin conversation management (for support agents)
      namespace :admin do
        resources :conversations, only: [:index, :show] do
          member do
            patch :assign_to_me
            patch :transfer
            patch 'status', to: 'conversations#update_status'
          end
        end
        
        # Admin analytics and reports
        get 'analytics/scanning', to: 'analytics#scanning_overview'
        get 'analytics/packages', to: 'analytics#package_analytics'
        get 'analytics/performance', to: 'analytics#performance_metrics'
        get 'analytics/fragile_packages', to: 'analytics#fragile_package_analytics'
      end

      # ==========================================
      # 📊 ANALYTICS & REPORTING (Role-Based)
      # ==========================================
      
      scope :analytics do
        # 📦 Package Analytics
        get :package_overview, to: 'analytics#package_overview'
        get :delivery_performance, to: 'analytics#delivery_performance'
        get :fragile_package_stats, to: 'analytics#fragile_package_statistics'
        
        # 👥 User Performance
        get :rider_performance, to: 'analytics#rider_performance'
        get :agent_performance, to: 'analytics#agent_performance'
        get :warehouse_performance, to: 'analytics#warehouse_performance'
        get :user_activity, to: 'analytics#user_activity'
        
        # 📱 Scanning Analytics
        get :scan_volume, to: 'analytics#scan_volume'
        get :scan_errors, to: 'analytics#scan_errors'
        get :offline_sync_stats, to: 'analytics#offline_sync_statistics'
        get :role_based_activity, to: 'analytics#role_based_scanning_activity'
        
        # 💰 Financial Analytics
        get :revenue_analysis, to: 'analytics#revenue_analysis'
        get :cost_breakdown, to: 'analytics#cost_breakdown'
        get :fragile_surcharge_impact, to: 'analytics#fragile_surcharge_impact'
        
        # 📍 Geographic Analytics
        get :route_performance, to: 'analytics#route_performance'
        get :area_activity, to: 'analytics#area_activity'
        get :warehouse_efficiency, to: 'analytics#warehouse_efficiency'
        
        # 📈 Trend Analysis
        get :trends, to: 'analytics#trend_analysis'
        get :forecasting, to: 'analytics#delivery_forecasting'
        
        # 🎨 QR Code Analytics - NEW
        get :qr_generation_stats, to: 'analytics#qr_generation_statistics'
        get :thermal_qr_usage, to: 'analytics#thermal_qr_usage_analytics'
        get :print_qr_comparison, to: 'analytics#print_vs_digital_qr_analytics'
      end

      # ==========================================
      # 🔧 SYSTEM CONFIGURATION & SETTINGS
      # ==========================================
      
      scope :settings do
        # 🖨️ Print Settings - ENHANCED
        get :print_configuration, to: 'settings#print_configuration'
        patch :update_print_config, to: 'settings#update_print_configuration'
        get :thermal_print_configuration, to: 'settings#thermal_print_configuration'  # 🖨️ NEW
        patch :update_thermal_config, to: 'settings#update_thermal_print_configuration' # 🖨️ NEW
        
        # 📱 Scanning Settings
        get :scan_configuration, to: 'settings#scan_configuration'
        patch :update_scan_config, to: 'settings#update_scan_configuration'
        
        # 💰 Pricing Settings
        get :pricing_configuration, to: 'settings#pricing_configuration'
        patch :update_pricing_config, to: 'settings#update_pricing_configuration'
        
        # ⚠️ Fragile Package Settings
        get :fragile_settings, to: 'settings#fragile_package_settings'
        patch :update_fragile_settings, to: 'settings#update_fragile_settings'
        
        # 🔄 Sync Settings
        get :sync_settings, to: 'settings#offline_sync_settings'
        patch :update_sync_settings, to: 'settings#update_sync_settings'
        
        # 👥 Role Management Settings
        get :role_permissions, to: 'settings#role_permissions'
        patch :update_role_permissions, to: 'settings#update_role_permissions'
        
        # 🎨 QR Code Settings - NEW
        get :qr_settings, to: 'settings#qr_code_settings'
        patch :update_qr_settings, to: 'settings#update_qr_code_settings'
        get :thermal_qr_settings, to: 'settings#thermal_qr_settings'
        patch :update_thermal_qr_settings, to: 'settings#update_thermal_qr_settings'
      end

      # ==========================================
      # 🔄 SYSTEM HEALTH & MONITORING
      # ==========================================
      
      scope :system do
        # 🏥 Health Checks
        get :health, to: 'system#health_check'
        get :printer_health, to: 'system#printer_health'
        get :thermal_printer_health, to: 'system#thermal_printer_health'  # 🖨️ NEW
        get :database_health, to: 'system#database_health'
        
        # 📊 System Stats
        get :stats, to: 'system#system_statistics'
        get :performance, to: 'system#performance_metrics'
        
        # 🔄 Background Jobs
        get :job_status, to: 'system#background_job_status'
        get :sync_queue, to: 'system#sync_queue_status'
        get :qr_generation_queue, to: 'system#qr_generation_queue_status'  # 🎨 NEW
        
        # 📝 System Logs
        get :logs, to: 'system#recent_logs'
        get :error_logs, to: 'system#error_logs'
        get :scan_logs, to: 'system#scanning_logs'
        get :qr_generation_logs, to: 'system#qr_generation_logs'  # 🎨 NEW
      end

      # ==========================================
      # 👥 ROLE-BASED ENDPOINTS
      # ==========================================

      # Client-specific endpoints
      scope :client do
        get :packages, to: 'packages#index' # Client's own packages
        get :tracking, to: 'tracking#client_packages'
        post :confirm_receipt, to: 'scanning#scan_action' # Alias for receipt confirmation
      end

      # Agent-specific endpoints
      scope :agent do
        get :packages, to: 'packages#agent_packages'
        get :print_queue, to: 'printing#agent_print_queue'
        post :print_labels, to: 'scanning#bulk_scan' # Alias for bulk printing
        post :print_thermal_labels, to: 'printing#bulk_thermal_print'  # 🖨️ NEW
        get :performance, to: 'analytics#agent_performance'
      end

      # Rider-specific endpoints
      scope :rider do
        get :packages, to: 'packages#rider_packages'
        get :routes, to: 'analytics#rider_routes'
        post :collect_packages, to: 'scanning#bulk_scan' # Alias for bulk collection
        post :deliver_packages, to: 'scanning#bulk_scan' # Alias for bulk delivery
        get :performance, to: 'analytics#rider_performance'
      end

      # Warehouse-specific endpoints
      scope :warehouse do
        get :packages, to: 'packages#warehouse_packages'
        get :processing_queue, to: 'packages#processing_queue'
        post :process_packages, to: 'scanning#bulk_scan' # Alias for bulk processing
        get :inventory, to: 'packages#warehouse_inventory'
        get :performance, to: 'analytics#warehouse_performance'
        post :print_thermal_batch, to: 'printing#warehouse_thermal_batch'  # 🖨️ NEW
      end

      # Admin-specific endpoints
      scope :admin do
        get :all_packages, to: 'packages#admin_index'
        get :system_overview, to: 'analytics#system_overview'
        get :user_management, to: 'users#admin_index'
        post :bulk_actions, to: 'scanning#admin_bulk_actions'
        get :audit_logs, to: 'system#audit_logs'
        get :qr_generation_overview, to: 'analytics#qr_generation_overview'  # 🎨 NEW
      end

      # ==========================================
      # 🏥 STATUS & HEALTH ENDPOINTS (Fixed)
      # ==========================================
      
      # API status and health endpoints
      get 'status', to: 'status#ping'
      get 'health', to: 'status#ping'
    end
  end

  # ==========================================
  # 🌐 PUBLIC ENDPOINTS (No Authentication Required)
  # ==========================================
  
  # Public package tracking - ENHANCED WITH QR SUPPORT
  scope :public do
    get 'track/:code', to: 'public/tracking#show', as: :public_package_tracking
    get 'track/:code/status', to: 'public/tracking#status'
    get 'track/:code/timeline', to: 'public/tracking#timeline'
    get 'track/:code/qr', to: 'public/tracking#qr_code'
    get 'track/:code/qr/organic', to: 'public/tracking#organic_qr_code'     # 🎨 NEW
    get 'track/:code/qr/thermal', to: 'public/tracking#thermal_qr_code'     # 🖨️ NEW
  end

  # Legacy public tracking (maintain compatibility)
  get 'api/v1/track/:code', to: 'api/v1/packages#public_tracking', as: :package_tracking

  # ==========================================
  # 🔗 WEBHOOK ENDPOINTS
  # ==========================================
  
  scope :webhooks do
    # Payment webhooks
    post 'payment/success', to: 'webhooks#payment_success'
    post 'payment/failed', to: 'webhooks#payment_failed'
    
    # External system integrations
    post 'tracking/update', to: 'webhooks#tracking_update'
    post 'delivery/notification', to: 'webhooks#delivery_notification'
    
    # Printer status webhooks - ENHANCED
    post 'printer/status', to: 'webhooks#printer_status_update'
    post 'printer/error', to: 'webhooks#printer_error'
    post 'thermal_printer/status', to: 'webhooks#thermal_printer_status_update'  # 🖨️ NEW
    post 'thermal_printer/error', to: 'webhooks#thermal_printer_error'           # 🖨️ NEW
    
    # Scanning system webhooks
    post 'scan/completed', to: 'webhooks#scan_completed'
    post 'bulk_scan/completed', to: 'webhooks#bulk_scan_completed'
    
    # QR Generation webhooks - NEW
    post 'qr_generation/completed', to: 'webhooks#qr_generation_completed'
    post 'thermal_qr/generated', to: 'webhooks#thermal_qr_generated'
    
    # Google OAuth webhooks
    post 'auth/google/success', to: 'webhooks#google_auth_success'
    post 'auth/google/failure', to: 'webhooks#google_auth_failure'
  end

  # ==========================================
  # 📱 MOBILE APP SPECIFIC ENDPOINTS
  # ==========================================
  
  scope :mobile do
    namespace :v1 do
      # 📦 Mobile-optimized package endpoints
      get 'packages/recent', to: 'mobile#recent_packages'
      get 'packages/my_scans', to: 'mobile#my_recent_scans'
      
      # 📱 Quick actions for mobile
      post 'quick_scan', to: 'mobile#quick_scan'
      post 'quick_print', to: 'mobile#quick_print'
      post 'quick_thermal_print', to: 'mobile#quick_thermal_print'  # 🖨️ NEW
      
      # 🔄 Mobile sync
      post 'sync', to: 'mobile#sync_data'
      get 'sync_status', to: 'mobile#sync_status'
      
      # 📊 Mobile dashboard
      get 'dashboard', to: 'mobile#dashboard_data'
      get 'notifications', to: 'mobile#notifications'
      
      # 📱 Role-specific mobile endpoints
      get 'role_dashboard', to: 'mobile#role_based_dashboard'
      get 'quick_actions', to: 'mobile#role_quick_actions'
      
      # 🎨 Mobile QR endpoints - NEW
      get 'qr_codes/recent', to: 'mobile#recent_qr_codes'
      post 'qr_codes/generate', to: 'mobile#generate_mobile_qr'
      get 'thermal_print/status', to: 'mobile#thermal_print_status'
      
      # 🔐 Mobile Google Auth - NEW
      post 'auth/google', to: 'mobile#google_login'
      post 'auth/refresh', to: 'mobile#refresh_token'
    end
  end

  # ==========================================
  # 🏥 HEALTH CHECK & STATUS
  # ==========================================
  
  # Rails health check
  get "up" => "rails/health#show", as: :rails_health_check
  
  # Custom health checks
  get "health/db" => "health#database", as: :database_health_check
  get "health/redis" => "health#redis", as: :redis_health_check if defined?(Redis)
  get "health/jobs" => "health#background_jobs", as: :jobs_health_check
  get "health/scanning" => "health#scanning_system", as: :scanning_health_check
  get "health/qr_generation" => "health#qr_generation_system", as: :qr_generation_health_check  # 🎨 NEW
  get "health/thermal_printing" => "health#thermal_printing_system", as: :thermal_printing_health_check  # 🖨️ NEW
  get "health/google_oauth" => "health#google_oauth_system", as: :google_oauth_health_check  # 🔐 NEW
  
  # ==========================================
  # 📱 PROGRESSIVE WEB APP SUPPORT
  # ==========================================
  
  # PWA manifest and service worker
  get '/manifest.json', to: 'pwa#manifest'
  get '/sw.js', to: 'pwa#service_worker'
  get '/offline', to: 'pwa#offline'

  # ==========================================
  # 🔀 CATCH-ALL AND REDIRECTS
  # ==========================================
  
  # Redirect root to API ping endpoint (uses existing controller)
  root 'api/v1/status#ping'
  
  # API documentation (if you have one)
  get '/docs', to: 'documentation#index'
  get '/api/docs', to: 'documentation#api_docs'
  get '/docs/qr_codes', to: 'documentation#qr_code_docs'  # 🎨 NEW
  get '/docs/google_auth', to: 'documentation#google_auth_docs'  # 🔐 NEW
  
  # ==========================================
  # 🚫 CATCH-ALL (FIXED - Excludes Active Storage paths)
  # ==========================================
  # ✅ CRITICAL FIX: This catch-all now excludes Active Storage paths
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