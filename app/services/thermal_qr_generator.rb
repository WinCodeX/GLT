# app/services/thermal_qr_generator.rb - Organic QR for thermal printers (pure B&W)

require 'rqrcode'
require 'chunky_png'

class ThermalQrGenerator
  attr_reader :package, :options

  def initialize(package, options = {})
    @package = package
    @options = thermal_default_options.merge(options)
  end

  # Generate thermal-optimized QR with organic styling
  def generate_thermal_qr
    Rails.logger.info "🖨️ [THERMAL-QR] Generating thermal QR for package: #{package.code}"
    
    # Create QR code data
    qr_data = generate_qr_data
    
    Rails.logger.info "📱 [THERMAL-QR] QR data to encode: #{qr_data}"
    
    # Generate QR code with optimal settings for thermal printing
    qrcode = RQRCode::QRCode.new(qr_data, level: :m, size: options[:qr_size])
    
    # Create thermal-optimized PNG (pure B&W, organic styling)
    create_thermal_png(qrcode)
  end

  # Generate base64 for thermal printer transmission
  def generate_thermal_base64
    png_data = generate_thermal_qr
    "data:image/png;base64,#{Base64.encode64(png_data)}"
  end

  # Generate bitmap data for direct thermal printer commands
  def generate_thermal_bitmap_data
    png_data = generate_thermal_qr
    
    # Convert PNG to monochrome bitmap array for ESC/POS
    convert_png_to_thermal_bitmap(png_data)
  end

  # Generate response for API consumption
  def generate_thermal_response
    {
      success: true,
      data: {
        # For ESC/POS commands
        qr_data: generate_qr_data,
        tracking_url: generate_tracking_url_safely,
        
        # Thermal-specific QR image (pure B&W)
        thermal_qr_base64: generate_thermal_base64,
        
        # Metadata
        package_code: package.code,
        qr_type: 'thermal_organic',
        thermal_optimized: true,
        
        # Thermal printer settings
        recommended_size: options[:module_size],
        error_correction: 'M',
        is_monochrome: true,
        
        generated_at: Time.current.iso8601
      }
    }
  rescue => e
    Rails.logger.error "❌ [THERMAL-QR] Failed to generate thermal QR: #{e.message}"
    {
      success: false,
      error: e.message,
      data: {
        qr_data: generate_qr_data,
        tracking_url: generate_tracking_url_safely,
        package_code: package.code,
        qr_type: 'fallback_text'
      }
    }
  end

  private

  def generate_qr_data
    # Use same data generation as organic QR for consistency
    tracking_url = generate_tracking_url_safely
    
    case options[:data_type]
    when :url
      tracking_url
    when :json
      {
        code: package.code,
        tracking_url: tracking_url,
        origin: package.origin_area&.name,
        destination: package.destination_area&.name,
        status: package.state
      }.to_json
    when :simple
      package.code
    else
      tracking_url # default
    end
  end

  def generate_tracking_url_safely
    begin
      host = Rails.application.config.action_mailer.default_url_options[:host]
      
      if host.present?
        protocol = Rails.env.production? ? 'https' : 'http'
        base_url = "#{protocol}://#{host}"
      else
        if Rails.env.production?
          base_url = ENV['APP_URL'] || 'https://your-app.railway.app'
        else
          base_url = 'http://localhost:3000'
        end
      end
      
      "#{base_url}/track/#{package.code}"
      
    rescue => e
      Rails.logger.warn "URL generation fallback triggered: #{e.message}"
      "/track/#{package.code}"
    end
  end

  def create_thermal_png(qrcode)
    # Calculate dimensions optimized for thermal printing
    module_size = options[:module_size]
    border_size = options[:border_size]
    qr_modules = qrcode.modules.size
    
    total_size = (qr_modules * module_size) + (border_size * 2)
    
    Rails.logger.info "🎨 [THERMAL-QR] Creating thermal PNG: #{total_size}x#{total_size}, modules: #{qr_modules}"
    
    # Create pure white canvas
    png = ChunkyPNG::Image.new(total_size, total_size, ChunkyPNG::Color::WHITE)
    
    # Draw QR code with thermal-optimized organic styling
    qrcode.modules.each_with_index do |row, row_index|
      row.each_with_index do |module_dark, col_index|
        next unless module_dark
        
        x = border_size + (col_index * module_size)
        y = border_size + (row_index * module_size)
        
        # Skip finder patterns - handle them separately for organic look
        if is_finder_pattern?(row_index, col_index, qr_modules)
          next
        end
        
        # Calculate organic corner radius (same algorithm as original)
        corner_radius = calculate_thermal_organic_corner_radius(qrcode.modules, row_index, col_index)
        
        if corner_radius > 0
          draw_thermal_organic_rounded_module(png, x, y, module_size, corner_radius)
        else
          draw_thermal_square_module(png, x, y, module_size)
        end
      end
    end
    
    # Draw organic finder patterns (thermal version)
    draw_thermal_organic_finder_patterns(png, qr_modules, module_size, border_size)
    
    # Add simplified center logo for thermal printing
    if options[:center_logo]
      add_thermal_center_logo(png, total_size)
    end
    
    Rails.logger.info "✅ [THERMAL-QR] Thermal PNG created successfully"
    png.to_blob
  end

  # Same organic corner calculation but for thermal constraints
  def calculate_thermal_organic_corner_radius(modules, row, col)
    max_radius = options[:corner_radius]
    return 0 if max_radius == 0
    
    # Check surrounding modules (same logic as organic version)
    neighbors = {
      top: row > 0 ? modules[row - 1][col] : false,
      bottom: row < modules.size - 1 ? modules[row + 1][col] : false,
      left: col > 0 ? modules[row][col - 1] : false,
      right: col < modules[row].size - 1 ? modules[row][col + 1] : false,
    }
    
    connected_sides = neighbors.values.count(true)
    
    # Same organic rounding algorithm but optimized for thermal printing
    case connected_sides
    when 0 then (max_radius * 1.8).to_i    # Slightly less aggressive for thermal
    when 1 then (max_radius * 1.4).to_i
    when 2 then (max_radius * 1.1).to_i
    when 3 then (max_radius * 0.8).to_i
    else (max_radius * 0.5).to_i
    end
  end

  # Thermal-optimized organic rounded module (pure B&W, no anti-aliasing)
  def draw_thermal_organic_rounded_module(png, x, y, size, radius)
    color = ChunkyPNG::Color::BLACK  # Pure black only
    
    # Clamp radius
    radius = [radius, size / 2].min
    
    # Draw main rectangle body
    if radius > 0
      png.rect(x + radius, y, x + size - radius - 1, y + size - 1, color, color)
      png.rect(x, y + radius, x + size - 1, y + size - radius - 1, color, color)
      
      # Draw thermal organic corners (no anti-aliasing)
      draw_thermal_organic_corner(png, x + radius, y + radius, radius, :top_left, color)
      draw_thermal_organic_corner(png, x + size - radius - 1, y + radius, radius, :top_right, color)
      draw_thermal_organic_corner(png, x + radius, y + size - radius - 1, radius, :bottom_left, color)
      draw_thermal_organic_corner(png, x + size - radius - 1, y + size - radius - 1, radius, :bottom_right, color)
    else
      png.rect(x, y, x + size - 1, y + size - 1, color, color)
    end
  end

  # Thermal organic corners (pure B&W, no anti-aliasing)
  def draw_thermal_organic_corner(png, cx, cy, radius, corner, color)
    # Simplified organic corner for thermal printing (no gradients)
    organic_factor = 1.2 # Slightly reduced for thermal clarity
    
    (0..(radius * organic_factor).to_i).each do |i|
      (0..(radius * organic_factor).to_i).each do |j|
        distance = Math.sqrt(i * i + j * j)
        
        # Pure B&W decision - no anti-aliasing
        next if distance > radius * organic_factor
        
        # Calculate plot position
        case corner
        when :top_left
          plot_x, plot_y = cx - i, cy - j
        when :top_right
          plot_x, plot_y = cx + i, cy - j
        when :bottom_left
          plot_x, plot_y = cx - i, cy + j
        when :bottom_right
          plot_x, plot_y = cx + i, cy + j
        end
        
        # Check bounds
        next if plot_x < 0 || plot_x >= png.width || plot_y < 0 || plot_y >= png.height
        
        # Pure black pixel (no blending for thermal)
        png[plot_x, plot_y] = color
      end
    end
  end

  # Simple thermal square module
  def draw_thermal_square_module(png, x, y, size)
    # Even square modules get slight organic rounding for thermal
    organic_radius = [size / 8, 1].max # Minimal rounding for thermal clarity
    draw_thermal_organic_rounded_module(png, x, y, size, organic_radius)
  end

  # Thermal-optimized organic finder patterns
  def draw_thermal_organic_finder_patterns(png, qr_size, module_size, border_size)
    finder_positions = [
      [0, 0],                    # Top-left
      [0, qr_size - 7],         # Top-right  
      [qr_size - 7, 0]          # Bottom-left
    ]
    
    finder_positions.each do |start_row, start_col|
      x = border_size + (start_col * module_size)
      y = border_size + (start_row * module_size)
      
      # Draw thermal organic finder pattern (7x7)
      outer_size = 7 * module_size
      outer_radius = (module_size * 2.0).to_i # Reduced for thermal clarity
      
      # Outer flowing square (pure black)
      draw_thermal_organic_rounded_rect(png, x, y, outer_size, outer_size, outer_radius, ChunkyPNG::Color::BLACK)
      
      # Inner white space with organic curves
      inner_x = x + module_size
      inner_y = y + module_size  
      inner_size = 5 * module_size
      inner_radius = (module_size * 1.5).to_i
      draw_thermal_organic_rounded_rect(png, inner_x, inner_y, inner_size, inner_size, inner_radius, ChunkyPNG::Color::WHITE)
      
      # Center organic square (pure black)
      center_x = x + 2 * module_size
      center_y = y + 2 * module_size
      center_size = 3 * module_size
      center_radius = (module_size * 1.0).to_i
      draw_thermal_organic_rounded_rect(png, center_x, center_y, center_size, center_size, center_radius, ChunkyPNG::Color::BLACK)
    end
  end

  # Thermal organic rounded rectangle (pure B&W)
  def draw_thermal_organic_rounded_rect(png, x, y, width, height, radius, color)
    radius = [radius, [width, height].min / 2].min
    
    # Draw main body
    png.rect(x + radius, y, x + width - radius - 1, y + height - 1, color, color)
    png.rect(x, y + radius, x + width - 1, y + height - radius - 1, color, color)
    
    # Draw thermal organic corners
    draw_thermal_organic_corner(png, x + radius, y + radius, radius, :top_left, color)
    draw_thermal_organic_corner(png, x + width - radius - 1, y + radius, radius, :top_right, color)
    draw_thermal_organic_corner(png, x + radius, y + height - radius - 1, radius, :bottom_left, color)
    draw_thermal_organic_corner(png, x + width - radius - 1, y + height - radius - 1, radius, :bottom_right, color)
  end

  def is_finder_pattern?(row, col, qr_size)
    finder_size = 7
    
    # Top-left finder
    return true if row < finder_size && col < finder_size
    # Top-right finder  
    return true if row < finder_size && col >= qr_size - finder_size
    # Bottom-left finder
    return true if row >= qr_size - finder_size && col < finder_size
    
    false
  end

  # Simplified thermal center logo (pure B&W)
  def add_thermal_center_logo(png, total_size)
    center_x = total_size / 2
    center_y = total_size / 2
    logo_size = options[:logo_size]
    
    logo_radius = logo_size / 2
    radius_int = logo_radius.to_i
    
    # Simple circular background (pure white)
    (-radius_int..radius_int).each do |x|
      (-radius_int..radius_int).each do |y|
        distance = Math.sqrt(x * x + y * y)
        next if distance > logo_radius
        
        plot_x = center_x + x
        plot_y = center_y + y
        
        next if plot_x < 0 || plot_x >= png.width || plot_y < 0 || plot_y >= png.height
        
        # Pure white background
        png[plot_x, plot_y] = ChunkyPNG::Color::WHITE
      end
    end
    
    # Draw simple thermal icon (pure black)
    draw_thermal_simple_icon(png, center_x, center_y, logo_size)
  end

  def draw_thermal_simple_icon(png, center_x, center_y, size)
    # Simple thermal-friendly icon (pure black lines)
    icon_color = ChunkyPNG::Color::BLACK
    half_size = (size / 4).to_i
    
    # Simple geometric shape for thermal printing
    (0..half_size).each do |i|
      x1 = (center_x - half_size + i).to_i
      y1 = (center_y - i).to_i
      y2 = (center_y + i).to_i
      x2 = (center_x + i).to_i
      y3 = center_y.to_i
      
      # Check bounds and draw
      png[x1, y1] = icon_color if x1.between?(0, png.width - 1) && y1.between?(0, png.height - 1)
      png[x1, y2] = icon_color if x1.between?(0, png.width - 1) && y2.between?(0, png.height - 1)
      png[x2, y3] = icon_color if x2.between?(0, png.width - 1) && y3.between?(0, png.height - 1)
    end
  end

  # Convert PNG to thermal bitmap array for ESC/POS commands
  def convert_png_to_thermal_bitmap(png_data)
    # This would convert the PNG to a bitmap array
    # For now, return the base64 - the frontend can handle ESC/POS conversion
    Base64.encode64(png_data)
  end

  # Thermal-optimized default options
  def thermal_default_options
    {
      module_size: 6,              # Smaller for thermal clarity
      border_size: 12,             # Reduced border
      corner_radius: 3,            # Conservative rounding for thermal
      qr_size: 5,                  # Compact QR for thermal
      data_type: :url,
      center_logo: false,          # Disabled by default for thermal
      logo_size: 16,               # Smaller logo if enabled
      
      # Thermal-specific options
      pure_monochrome: true,
      anti_aliasing: false,
      thermal_optimized: true
    }
  end
end