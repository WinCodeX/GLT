# app/helpers/public/packages_helper.rb

module Public
  module PackagesHelper
    # Delivery type configurations with metadata
    DELIVERY_TYPES = {
      'fragile' => {
        name: 'Fragile Items',
        icon: '⚠️',
        description: 'Premium care for delicate items requiring special handling',
        color: '#FF9500',
        base_fee: 150,
        type_fee: 150,
        features: [
          'Extra protective packaging',
          'Careful handling guarantee',
          'Insurance coverage included'
        ]
      },
      'home' => {
        name: 'Home Delivery',
        icon: '🏠',
        description: 'Convenient doorstep delivery to residential addresses',
        color: '#8b5cf6',
        base_fee: 150,
        type_fee: 100,
        features: [
          'Same-day delivery available',
          'Real-time GPS tracking',
          'Flexible time slots'
        ]
      },
      'doorstep' => {
        name: 'Doorstep Delivery',
        icon: '🚪',
        description: 'Direct delivery to your doorstep',
        color: '#8b5cf6',
        base_fee: 150,
        type_fee: 100,
        features: [
          'Direct to door',
          'Photo proof of delivery',
          'Contactless option'
        ]
      },
      'office' => {
        name: 'Office Delivery',
        icon: '💼',
        description: 'Professional business delivery with reception coordination',
        color: '#3b82f6',
        base_fee: 150,
        type_fee: 50,
        features: [
          'Business hours delivery',
          'Bulk delivery options',
          'Corporate accounts'
        ]
      },
      'agent' => {
        name: 'Agent Pickup',
        icon: '🏪',
        description: 'Pick up from designated agent locations',
        color: '#f59e0b',
        base_fee: 150,
        type_fee: 0,
        features: [
          'Extended pickup hours',
          'Secure storage',
          'Nationwide network'
        ]
      },
      'collection' => {
        name: 'Collection & Delivery',
        icon: '📦',
        description: 'We collect and deliver multiple packages efficiently',
        color: '#10b981',
        base_fee: 150,
        type_fee: 200,
        features: [
          'Multiple pickup points',
          'Package consolidation',
          'Cost-effective rates'
        ]
      }
    }.freeze

    # Get delivery type configuration
    def delivery_type_config(type)
      DELIVERY_TYPES[type.to_s] || DELIVERY_TYPES['home']
    end

    # Get delivery type name
    def delivery_type_name(type)
      delivery_type_config(type)[:name]
    end

    # Get delivery type icon
    def delivery_type_icon(type)
      delivery_type_config(type)[:icon]
    end

    # Get delivery type color
    def delivery_type_color(type)
      delivery_type_config(type)[:color]
    end

    # Get delivery type description
    def delivery_type_description(type)
      delivery_type_config(type)[:description]
    end

    # Get delivery type features
    def delivery_type_features(type)
      delivery_type_config(type)[:features]
    end

    # Check if delivery type requires special fields
    def requires_collection_fields?(type)
      type.to_s == 'collection'
    end

    def requires_fragile_fields?(type)
      type.to_s == 'fragile'
    end

    def requires_area_selection?(type)
      %w[home office agent doorstep].include?(type.to_s)
    end

    # Format package size for display
    def format_package_size(size)
      {
        'small' => 'Small (up to 5kg)',
        'medium' => 'Medium (5-15kg)',
        'large' => 'Large (15kg+)'
      }[size.to_s] || size.to_s.humanize
    end

    # Get badge color for delivery type
    def delivery_type_badge_class(type)
      {
        'fragile' => 'badge-warning',
        'home' => 'badge-primary',
        'doorstep' => 'badge-primary',
        'office' => 'badge-info',
        'agent' => 'badge-secondary',
        'collection' => 'badge-success'
      }[type.to_s] || 'badge-primary'
    end
  end
end