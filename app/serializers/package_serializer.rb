# app/serializers/package_serializer.rb - FIXED
class PackageSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :id, :code, :state, :delivery_type, :cost, :sender_name, :sender_phone, 
             :receiver_name, :receiver_phone, :created_at, :updated_at
  
  belongs_to :origin_area, serializer: AreaSerializer
  belongs_to :destination_area, serializer: AreaSerializer
  belongs_to :origin_agent, serializer: AgentSerializer
  belongs_to :destination_agent, serializer: AgentSerializer
  belongs_to :user, serializer: UserSerializer
  
  attribute :tracking_code do |package|
    package.code
  end
  
  attribute :state_display do |package|
    package.state&.humanize || 'Unknown'
  end
  
  attribute :route_description do |package|
    if package.respond_to?(:route_description)
      package.route_description
    else
      # Fallback route description generation
      origin_location = package.origin_area&.location&.name || 'Unknown Origin'
      destination_location = package.destination_area&.location&.name || 'Unknown Destination'
      
      if package.origin_area&.location&.id == package.destination_area&.location&.id
        origin_area = package.origin_area&.name || 'Unknown Area'
        destination_area = package.destination_area&.name || 'Unknown Area'
        "#{origin_location} (#{origin_area} → #{destination_area})"
      else
        "#{origin_location} → #{destination_location}"
      end
    end
  end
  
  attribute :is_intra_area do |package|
    package.respond_to?(:intra_area_shipment?) ? package.intra_area_shipment? : false
  end
  
  attribute :is_paid do |package|
    package.respond_to?(:paid?) ? package.paid? : (package.state != 'pending_unpaid')
  end
  
  attribute :is_trackable do |package|
    package.respond_to?(:trackable?) ? package.trackable? : true
  end
  
  attribute :can_be_cancelled do |package|
    package.respond_to?(:can_be_cancelled?) ? package.can_be_cancelled? : ['pending_unpaid', 'pending'].include?(package.state)
  end
  
  attribute :tracking_url do |package, params|
    begin
      if package.respond_to?(:tracking_url)
        package.tracking_url
      else
        # Generate tracking URL using helper
        if params && params[:url_helper]
          params[:url_helper].tracking_url_for(package.code)
        else
          # Fallback URL generation
          protocol = Rails.env.production? ? 'https' : 'http'
          host = Rails.application.config.action_mailer.default_url_options[:host] || 'localhost:3000'
          "#{protocol}://#{host}/track/#{package.code}"
        end
      end
    rescue => e
      Rails.logger.warn "Failed to generate tracking URL for package #{package.id}: #{e.message}"
      "/track/#{package.code}"
    end
  end
  
  # FIXED: Enhanced QR code attribute with proper error handling
  attribute :qr_code_base64, if: Proc.new { |record, params|
    params && params[:include_qr_code]
  } do |package, params|
    begin
      Rails.logger.info "🔲 Generating QR code for package: #{package.code}"
      
      qr_options = params[:qr_options] || {}
      
      # Try package's own method first
      if package.respond_to?(:qr_code_base64)
        Rails.logger.info "📱 Using package's qr_code_base64 method"
        result = package.qr_code_base64(qr_options)
        Rails.logger.info "📱 Package QR method result: #{result ? 'SUCCESS' : 'FAILED'}"
        return result
      end
      
      # Fallback: Use QrCodeGenerator service directly
      if defined?(QrCodeGenerator)
        Rails.logger.info "🎨 Using QrCodeGenerator service"
        qr_generator = QrCodeGenerator.new(package, qr_options)
        png_data = qr_generator.generate
        result = "data:image/png;base64,#{Base64.encode64(png_data)}"
        Rails.logger.info "🎨 QrCodeGenerator result: SUCCESS"
        return result
      end
      
      # Simple RQRCode fallback
      if defined?(RQRCode)
        Rails.logger.info "📱 Using simple RQRCode fallback"
        
        tracking_url = if params[:url_helper]
          params[:url_helper].tracking_url_for(package.code)
        else
          "/track/#{package.code}"
        end
        
        qrcode = RQRCode::QRCode.new(tracking_url, level: :m, size: 4)
        
        # Check if chunky_png is available for styled QR
        if defined?(ChunkyPNG)
          png = qrcode.as_png(
            resize_gte_to: false,
            resize_exactly_to: false,
            fill: 'white',
            color: '#7c3aed',
            size: 240,
            border_modules: 3
          )
          result = "data:image/png;base64,#{Base64.encode64(png.to_s)}"
          Rails.logger.info "📱 Simple styled QR result: SUCCESS"
          return result
        else
          # Ultra-simple SVG fallback
          svg = qrcode.as_svg(
            color: '7c3aed',
            shape_rendering: 'crispEdges',
            module_size: 6,
            standalone: true,
            use_path: true
          )
          result = "data:image/svg+xml;base64,#{Base64.encode64(svg)}"
          Rails.logger.info "📱 SVG QR result: SUCCESS"
          return result
        end
      end
      
      Rails.logger.warn "⚠️ No QR generation method available"
      nil
      
    rescue => e
      Rails.logger.error "❌ QR code generation failed in serializer: #{e.message}"
      Rails.logger.error "❌ QR error details: #{e.backtrace.first(5).join("\n")}"
      nil
    end
  end
end