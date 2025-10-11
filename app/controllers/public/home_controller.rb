# app/controllers/public/home_controller.rb
module Public
  class HomeController < WebApplicationController
    # Skip authentication for public access
    skip_before_action :authenticate_user!
    
    # No layout needed - view is complete HTML document
    layout false
    
    # Landing page
    def index
      # Load stats for the hero section
      @stats = calculate_stats
      
      # Load featured services
      @services = load_services
      
      # Load features
      @features = load_features
      
      respond_to do |format|
        format.html
        format.json { render json: landing_page_json }
      end
    rescue => e
      Rails.logger.error "Error loading landing page: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render :error, status: :internal_server_error
    end

    private

    # Calculate platform statistics
    def calculate_stats
      {
        businesses: '25K+',
        shoppers: '100K+',
        packages: '1M+',
        gmv: '500M+'
      }
    rescue => e
      Rails.logger.error "Error calculating stats: #{e.message}"
      # Return default values on error
      {
        businesses: '25K+',
        shoppers: '100K+',
        packages: '1M+',
        gmv: '500M+'
      }
    end

    # Load service definitions
    def load_services
      [
        {
          id: 'fragile',
          title: 'Fragile Items',
          description: 'Special handling for delicate items that require extra care during transport',
          icon: '⚠️',
          color: '#FF9500',
          features: [
            'Extra protective packaging',
            'Careful handling guarantee',
            'Insurance coverage included'
          ],
          cta_text: 'Schedule Fragile Delivery',
          cta_url: sign_in_path
        },
        {
          id: 'home',
          title: 'Home Delivery',
          description: 'Convenient door-to-door delivery service to residential addresses',
          icon: '🏠',
          color: '#8b5cf6',
          features: [
            'Same-day delivery available',
            'Real-time tracking',
            'Flexible delivery windows'
          ],
          cta_text: 'Send to Home',
          cta_url: sign_in_path
        },
        {
          id: 'office',
          title: 'Office Delivery',
          description: 'Professional delivery service to business and office locations',
          icon: '💼',
          color: '#3b82f6',
          features: [
            'Business hours delivery',
            'Reception desk drop-off',
            'Bulk delivery options'
          ],
          cta_text: 'Send to Office',
          cta_url: sign_in_path
        },
        {
          id: 'collection',
          title: 'Collection & Delivery',
          description: 'We pick up, consolidate, and deliver multiple packages to your location',
          icon: '📦',
          color: '#10b981',
          features: [
            'Multiple pickup points',
            'Package consolidation',
            'Cost-effective solution'
          ],
          cta_text: 'Request Collection',
          cta_url: sign_in_path
        }
      ]
    rescue => e
      Rails.logger.error "Error loading services: #{e.message}"
      []
    end

    # Load feature definitions
    def load_features
      [
        {
          id: 'tracking',
          title: 'Real-Time Tracking',
          description: 'Track your packages in real-time with detailed status updates and location information',
          icon: '📍'
        },
        {
          id: 'payment',
          title: 'Pay on Delivery',
          description: 'Flexible payment options with instant withdrawals to your M-Pesa or Airtel Money',
          icon: '💳'
        },
        {
          id: 'speed',
          title: 'Fast Delivery',
          description: 'Quick and efficient delivery across all major cities and towns in Kenya',
          icon: '⚡'
        },
        {
          id: 'security',
          title: 'Secure Handling',
          description: 'Your packages are handled with care and security throughout the delivery process',
          icon: '🔒'
        }
      ]
    rescue => e
      Rails.logger.error "Error loading features: #{e.message}"
      []
    end

    # JSON response for landing page data
    def landing_page_json
      {
        stats: @stats,
        services: @services,
        features: @features,
        tracking_url: public_tracking_index_path,
        sign_in_url: sign_in_path
      }
    rescue => e
      Rails.logger.error "Error building landing page JSON: #{e.message}"
      { error: 'Error loading landing page data' }
    end
  end
end