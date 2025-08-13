# =====================================================
# ENHANCED: app/services/qr_code_generator.rb
# =====================================================

require 'rqrcode'
require 'chunky_png'

class QrCodeGenerator
  attr_reader :package, :options

  def initialize(package, options = {})
    @package = package
    @options = default_options.merge(options)
  end

  def generate
    # Create QR code data
    qr_data = generate_qr_data
    
    Rails.logger.info "📱 QR data to encode: #{qr_data}"
    
    # Generate QR code
    qrcode = RQRCode::QRCode.new(qr_data, level: :h, size: options[:qr_size])
    
    # Create styled PNG with smooth circular modules
    create_smooth_styled_png(qrcode)
  end

  def generate_and_save
    png_data = generate
    filename = "package_#{package.code}_qr.png"
    file_path = Rails.root.join('tmp', 'qr_codes', filename)
    
    # Ensure directory exists
    FileUtils.mkdir_p(File.dirname(file_path))
    
    # Save file
    File.open(file_path, 'wb') { |f| f.write(png_data) }
    
    file_path
  end

  def generate_base64
    png_data = generate
    "data:image/png;base64,#{Base64.encode64(png_data)}"
  end

  private

  def generate_qr_data
    # Generate URL without requiring request context
    tracking_url = generate_tracking_url_safely
    
    Rails.logger.info "📱 Generated tracking URL: #{tracking_url}"
    
    # Return appropriate data based on type
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
      # Try to get configured host from application config
      host = Rails.application.config.action_mailer.default_url_options[:host]
      
      if host.present?
        protocol = Rails.env.production? ? 'https' : 'http'
        base_url = "#{protocol}://#{host}"
      else
        # Fallback to environment-based defaults
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

  def create_smooth_styled_png(qrcode)
    # Calculate dimensions with higher resolution for smoother output
    module_size = options[:module_size] * 2 # Double resolution for smoothness
    border_size = options[:border_size] * 2
    qr_modules = qrcode.modules.size
    
    total_size = (qr_modules * module_size) + (border_size * 2)
    
    Rails.logger.info "🎨 Creating smooth PNG: #{total_size}x#{total_size}, modules: #{qr_modules}"
    
    # Create high-resolution canvas
    png = ChunkyPNG::Image.new(total_size, total_size, options[:background_color])
    
    # First pass: Draw QR code with enhanced circular modules
    qrcode.modules.each_with_index do |row, row_index|
      row.each_with_index do |module_dark, col_index|
        next unless module_dark
        
        x = border_size + (col_index * module_size)
        y = border_size + (row_index * module_size)
        
        # Check if this is a finder pattern (corner squares)
        if is_finder_pattern?(row_index, col_index, qr_modules)
          draw_smooth_finder_pattern(png, qrcode.modules, row_index, col_index, x, y, module_size)
        else
          # Regular modules with enhanced smoothness
          smoothness_factor = calculate_smoothness_factor(qrcode.modules, row_index, col_index)
          draw_smooth_circular_module(png, x, y, module_size, smoothness_factor)
        end
      end
    end
    
    # Apply gradient effect for premium look
    if options[:gradient]
      apply_smooth_gradient_effect(png)
    end
    
    # Add refined center logo
    if options[:center_logo]
      add_refined_center_logo(png, total_size)
    end
    
    # Scale down to target size with anti-aliasing
    final_size = total_size / 2
    scaled_png = scale_with_antialiasing(png, final_size, final_size)
    
    Rails.logger.info "✅ Smooth PNG created successfully"
    scaled_png.to_blob
  end

  def is_finder_pattern?(row, col, size)
    # Check if current position is part of finder patterns (3 corner squares)
    finder_size = 7
    
    # Top-left finder
    return true if row < finder_size && col < finder_size
    
    # Top-right finder  
    return true if row < finder_size && col >= size - finder_size
    
    # Bottom-left finder
    return true if row >= size - finder_size && col < finder_size
    
    false
  end

  def draw_smooth_finder_pattern(png, modules, start_row, start_col, x, y, module_size)
    # Draw finder pattern with circular/rounded appearance
    
    # Get the current finder pattern position
    finder_row = start_row % 7
    finder_col = start_col % 7
    
    # Create circular modules for finder patterns
    radius = module_size * 0.45 # Almost circular
    
    # For outer ring (7x7) and inner square (3x3), use different styles
    if is_finder_outer_ring?(finder_row, finder_col)
      # Outer ring - use rounded rectangles
      draw_circular_module(png, x, y, module_size, radius * 0.9)
    elsif is_finder_inner_square?(finder_row, finder_col)
      # Inner square - use full circles
      draw_circular_module(png, x, y, module_size, radius)
    end
  end

  def is_finder_outer_ring?(row, col)
    # Check if position is part of the outer ring of finder pattern
    (row == 0 || row == 6 || col == 0 || col == 6) && 
    !(row >= 2 && row <= 4 && col >= 2 && col <= 4)
  end

  def is_finder_inner_square?(row, col)
    # Check if position is part of inner 3x3 square
    row >= 2 && row <= 4 && col >= 2 && col <= 4
  end

  def calculate_smoothness_factor(modules, row, col)
    # Calculate how "isolated" a module is to determine roundness
    neighbors_count = 0
    corner_connections = 0
    
    # Check 8 surrounding positions
    (-1..1).each do |dr|
      (-1..1).each do |dc|
        next if dr == 0 && dc == 0 # Skip self
        
        new_row = row + dr
        new_col = col + dc
        
        # Check bounds
        next if new_row < 0 || new_row >= modules.size
        next if new_col < 0 || new_col >= modules[new_row].size
        
        if modules[new_row][new_col]
          neighbors_count += 1
          # Check if it's a corner connection
          corner_connections += 1 if dr.abs == 1 && dc.abs == 1
        end
      end
    end
    
    # Return smoothness factor (0.1 = very round, 0.9 = almost square)
    case neighbors_count
    when 0..1 then 0.8 # Very isolated = very round
    when 2..3 then 0.6 # Somewhat isolated = medium round  
    when 4..5 then 0.4 # Connected = slight rounding
    else 0.3 # Highly connected = minimal rounding
    end
  end

  def draw_smooth_circular_module(png, x, y, size, smoothness_factor)
    color = options[:foreground_color]
    center_x = x + size / 2.0
    center_y = y + size / 2.0
    
    # Calculate effective radius based on smoothness
    max_radius = size / 2.0
    effective_radius = max_radius * smoothness_factor
    
    # Draw anti-aliased circular module
    (0...size).each do |dx|
      (0...size).each do |dy|
        pixel_x = x + dx
        pixel_y = y + dy
        
        # Calculate distance from center
        distance_from_center = Math.sqrt((dx - size/2.0)**2 + (dy - size/2.0)**2)
        
        if distance_from_center <= effective_radius
          # Inside the circular area
          alpha = calculate_antialiasing_alpha(distance_from_center, effective_radius)
          blended_color = blend_colors(options[:background_color], color, alpha)
          png[pixel_x, pixel_y] = blended_color
        end
      end
    end
  end

  def draw_circular_module(png, x, y, size, radius)
    color = options[:foreground_color]
    center_x = x + size / 2.0
    center_y = y + size / 2.0
    
    # Draw perfect circle
    (0...size).each do |dx|
      (0...size).each do |dy|
        pixel_x = x + dx
        pixel_y = y + dy
        
        distance_from_center = Math.sqrt((dx - size/2.0)**2 + (dy - size/2.0)**2)
        
        if distance_from_center <= radius
          alpha = calculate_antialiasing_alpha(distance_from_center, radius)
          blended_color = blend_colors(options[:background_color], color, alpha)
          png[pixel_x, pixel_y] = blended_color
        end
      end
    end
  end

  def calculate_antialiasing_alpha(distance, radius)
    if distance <= radius - 0.5
      1.0 # Fully opaque
    elsif distance <= radius + 0.5
      # Anti-aliasing zone
      0.5 + (radius - distance)
    else
      0.0 # Transparent
    end
  end

  def blend_colors(background, foreground, alpha)
    # Extract RGB components
    bg_r = (background >> 24) & 0xff
    bg_g = (background >> 16) & 0xff  
    bg_b = (background >> 8) & 0xff
    
    fg_r = (foreground >> 24) & 0xff
    fg_g = (foreground >> 16) & 0xff
    fg_b = (foreground >> 8) & 0xff
    
    # Blend colors
    r = (bg_r + (fg_r - bg_r) * alpha).to_i
    g = (bg_g + (fg_g - bg_g) * alpha).to_i
    b = (bg_b + (fg_b - bg_b) * alpha).to_i
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  def apply_smooth_gradient_effect(png)
    # Apply smooth gradient from purple to blue like in the image
    width = png.width
    height = png.height
    
    png.width.times do |x|
      png.height.times do |y|
        current_pixel = png[x, y]
        
        # Skip background pixels
        next if current_pixel == options[:background_color]
        
        # Calculate gradient position (diagonal gradient)
        ratio = Math.sqrt((x.to_f / width)**2 + (y.to_f / height)**2) / Math.sqrt(2)
        ratio = [ratio, 1.0].min # Clamp to 1.0
        
        # Smooth interpolation between gradient colors
        new_color = smooth_interpolate_color(options[:gradient_start], options[:gradient_end], ratio)
        png[x, y] = new_color
      end
    end
  end

  def smooth_interpolate_color(color1, color2, ratio)
    # Smooth color interpolation with gamma correction
    gamma = 2.2
    
    # Extract components
    r1 = ((color1 >> 24) & 0xff) / 255.0
    g1 = ((color1 >> 16) & 0xff) / 255.0
    b1 = ((color1 >> 8) & 0xff) / 255.0
    
    r2 = ((color2 >> 24) & 0xff) / 255.0
    g2 = ((color2 >> 16) & 0xff) / 255.0
    b2 = ((color2 >> 8) & 0xff) / 255.0
    
    # Apply gamma correction for smoother gradients
    r1_gamma = r1 ** gamma
    g1_gamma = g1 ** gamma
    b1_gamma = b1 ** gamma
    
    r2_gamma = r2 ** gamma
    g2_gamma = g2 ** gamma
    b2_gamma = b2 ** gamma
    
    # Interpolate in gamma space
    r_gamma = r1_gamma + (r2_gamma - r1_gamma) * ratio
    g_gamma = g1_gamma + (g2_gamma - g1_gamma) * ratio
    b_gamma = b1_gamma + (b2_gamma - b1_gamma) * ratio
    
    # Convert back from gamma space
    r = ((r_gamma ** (1.0/gamma)) * 255).to_i
    g = ((g_gamma ** (1.0/gamma)) * 255).to_i
    b = ((b_gamma ** (1.0/gamma)) * 255).to_i
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  def add_refined_center_logo(png, total_size)
    # Create a refined paper plane logo like in the image
    center_x = total_size / 2
    center_y = total_size / 2
    logo_size = options[:logo_size] * 2 # Larger for high-res
    
    # Create smooth circular background
    logo_radius = logo_size / 2
    logo_bg_color = ChunkyPNG::Color.rgba(124, 58, 237, 220) # Slightly transparent purple
    
    # Draw smooth circular background
    (-logo_radius..logo_radius).each do |x|
      (-logo_radius..logo_radius).each do |y|
        distance = Math.sqrt(x * x + y * y)
        
        if distance <= logo_radius
          # Anti-aliased circle edge
          alpha = distance <= logo_radius - 1 ? 1.0 : (logo_radius - distance)
          alpha = [alpha, 0.0].max
          
          blended_color = blend_colors(png[center_x + x, center_y + y], logo_bg_color, alpha * 0.9)
          png[center_x + x, center_y + y] = blended_color
        end
      end
    end
    
    # Draw refined paper plane icon
    draw_refined_paper_plane(png, center_x, center_y, logo_size)
  end

  def draw_refined_paper_plane(png, center_x, center_y, size)
    icon_color = ChunkyPNG::Color::WHITE
    icon_size = size * 0.4
    
    # Paper plane shape coordinates (more refined)
    points = [
      # Main triangle body
      [center_x - icon_size*0.3, center_y - icon_size*0.4],
      [center_x + icon_size*0.4, center_y],
      [center_x - icon_size*0.3, center_y + icon_size*0.4],
      [center_x - icon_size*0.1, center_y]
    ]
    
    # Draw filled triangle with anti-aliasing
    draw_smooth_polygon(png, points, icon_color)
    
    # Add wing details
    wing_points = [
      [center_x - icon_size*0.1, center_y - icon_size*0.2],
      [center_x + icon_size*0.1, center_y - icon_size*0.3],
      [center_x + icon_size*0.2, center_y - icon_size*0.1],
      [center_x, center_y]
    ]
    
    draw_smooth_polygon(png, wing_points, icon_color)
  end

  def draw_smooth_polygon(png, points, color)
    # Simple polygon fill with anti-aliasing
    min_x = points.map { |p| p[0] }.min.to_i
    max_x = points.map { |p| p[0] }.max.to_i
    min_y = points.map { |p| p[1] }.min.to_i
    max_y = points.map { |p| p[1] }.max.to_i
    
    (min_x..max_x).each do |x|
      (min_y..max_y).each do |y|
        if point_in_polygon?(x, y, points)
          png[x, y] = color
        end
      end
    end
  end

  def point_in_polygon?(x, y, points)
    # Ray casting algorithm for point-in-polygon test
    inside = false
    j = points.length - 1
    
    points.each_with_index do |point, i|
      xi, yi = point
      xj, yj = points[j]
      
      if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
        inside = !inside
      end
      
      j = i
    end
    
    inside
  end

  def scale_with_antialiasing(png, target_width, target_height)
    # Simple nearest neighbor scaling (can be enhanced with bilinear)
    scaled = ChunkyPNG::Image.new(target_width, target_height, options[:background_color])
    
    x_ratio = png.width.to_f / target_width
    y_ratio = png.height.to_f / target_height
    
    target_width.times do |x|
      target_height.times do |y|
        # Sample from original image
        orig_x = (x * x_ratio).to_i
        orig_y = (y * y_ratio).to_i
        
        scaled[x, y] = png[orig_x, orig_y]
      end
    end
    
    scaled
  end

  def default_options
    {
      module_size: 10,          # Increased for smoother rendering
      border_size: 25,          # Increased border for better proportions
      corner_radius: 8,         # Higher radius for more rounding
      qr_size: 6,              # Optimal size for readability
      background_color: ChunkyPNG::Color::WHITE,
      foreground_color: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      data_type: :url,
      center_logo: true,
      logo_size: 35,           # Larger logo for better visibility
      logo_color: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      gradient: true,          # Enable gradient by default for premium look
      gradient_start: ChunkyPNG::Color.rgb(124, 58, 237), # Purple (#7c3aed)
      gradient_end: ChunkyPNG::Color.rgb(59, 130, 246)    # Blue (#3b82f6)
    }
  end
end