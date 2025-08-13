# =====================================================
# UPDATED: app/services/qr_code_generator.rb - Smooth Circular Design
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
    
    # Create smooth styled PNG
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
      tracking_url
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
      Rails.logger.warn "URL generation fallback: #{e.message}"
      "/track/#{package.code}"
    end
  end

  def create_smooth_styled_png(qrcode)
    # Calculate dimensions
    module_size = options[:module_size]
    border_size = options[:border_size]
    qr_modules = qrcode.modules.size
    
    total_size = (qr_modules * module_size) + (border_size * 2)
    
    Rails.logger.info "🎨 Creating smooth PNG: #{total_size}x#{total_size}, modules: #{qr_modules}"
    
    # Create canvas with anti-aliasing support
    png = ChunkyPNG::Image.new(total_size, total_size, options[:background_color])
    
    # Identify finder patterns (the three corner squares)
    finder_patterns = identify_finder_patterns(qr_modules)
    
    # Draw QR modules with smooth, rounded styling
    qrcode.modules.each_with_index do |row, row_index|
      row.each_with_index do |module_dark, col_index|
        next unless module_dark
        
        x = border_size + (col_index * module_size)
        y = border_size + (row_index * module_size)
        
        # Check if this module is part of a finder pattern
        if finder_pattern_module?(finder_patterns, row_index, col_index)
          draw_smooth_finder_module(png, x, y, module_size, row_index, col_index, finder_patterns)
        else
          # Regular modules get smooth circular treatment
          draw_smooth_circular_module(png, x, y, module_size, qrcode.modules, row_index, col_index)
        end
      end
    end
    
    # Add center logo if specified
    if options[:center_logo]
      add_center_logo(png, total_size)
    end
    
    # Add gradient effect if specified
    if options[:gradient]
      apply_smooth_gradient_effect(png)
    end
    
    Rails.logger.info "✅ Smooth PNG created successfully"
    png.to_blob
  end

  # Identify the three finder patterns (corner squares)
  def identify_finder_patterns(size)
    [
      { row: 3, col: 3, size: 7 },     # Top-left
      { row: 3, col: size - 4, size: 7 }, # Top-right  
      { row: size - 4, col: 3, size: 7 }  # Bottom-left
    ]
  end

  # Check if a module is part of any finder pattern
  def finder_pattern_module?(finder_patterns, row, col)
    finder_patterns.any? do |pattern|
      (row - pattern[:row]).abs <= 3 && (col - pattern[:col]).abs <= 3
    end
  end

  # Draw smooth finder pattern modules (corner squares)
  def draw_smooth_finder_module(png, x, y, module_size, row, col, finder_patterns)
    # Find which finder pattern this belongs to
    pattern = finder_patterns.find do |p|
      (row - p[:row]).abs <= 3 && (col - p[:col]).abs <= 3
    end
    
    return unless pattern
    
    # Calculate position within finder pattern
    rel_row = row - (pattern[:row] - 3)
    rel_col = col - (pattern[:col] - 3)
    
    # Create smooth, almost circular finder patterns
    if finder_outer_ring?(rel_row, rel_col)
      # Outer ring - very rounded
      draw_circular_module(png, x, y, module_size, 0.9)
    elsif finder_inner_square?(rel_row, rel_col)
      # Inner square - completely circular
      draw_circular_module(png, x, y, module_size, 1.0)
    end
  end

  # Check if module is part of finder pattern outer ring
  def finder_outer_ring?(rel_row, rel_col)
    # 7x7 finder pattern outer ring
    (rel_row == 0 || rel_row == 6 || rel_col == 0 || rel_col == 6) &&
    rel_row.between?(0, 6) && rel_col.between?(0, 6)
  end

  # Check if module is part of finder pattern inner square
  def finder_inner_square?(rel_row, rel_col)
    # 3x3 inner square of finder pattern
    rel_row.between?(2, 4) && rel_col.between?(2, 4)
  end

  # Draw smooth circular module
  def draw_circular_module(png, x, y, size, roundness = 0.8)
    color = options[:foreground_color]
    center_x = x + size / 2.0
    center_y = y + size / 2.0
    radius = (size / 2.0) * roundness
    
    # Draw anti-aliased circle
    (x...(x + size)).each do |px|
      (y...(y + size)).each do |py|
        distance = Math.sqrt((px - center_x)**2 + (py - center_y)**2)
        
        if distance <= radius
          # Solid color for inner area
          png[px, py] = color
        elsif distance <= radius + 1.0
          # Anti-aliasing for smooth edges
          alpha = 1.0 - (distance - radius)
          anti_aliased_color = blend_colors(options[:background_color], color, alpha)
          png[px, py] = anti_aliased_color
        end
      end
    end
  end

  # Draw smooth circular module for regular data modules
  def draw_smooth_circular_module(png, x, y, size, modules, row, col)
    # Determine smoothness based on isolation
    isolation_factor = calculate_isolation_factor(modules, row, col)
    roundness = 0.3 + (isolation_factor * 0.5) # 0.3 to 0.8 roundness
    
    draw_circular_module(png, x, y, size, roundness)
  end

  # Calculate how isolated a module is (for variable roundness)
  def calculate_isolation_factor(modules, row, col)
    neighbors = []
    
    # Check 8 surrounding positions
    (-1..1).each do |dr|
      (-1..1).each do |dc|
        next if dr == 0 && dc == 0 # Skip self
        
        nr, nc = row + dr, col + dc
        if nr.between?(0, modules.size - 1) && nc.between?(0, modules[0].size - 1)
          neighbors << modules[nr][nc]
        else
          neighbors << false # Edge counts as empty
        end
      end
    end
    
    # More isolated modules get more rounding
    empty_neighbors = neighbors.count(false)
    empty_neighbors / 8.0 # Return ratio of empty neighbors
  end

  # Blend two colors with alpha
  def blend_colors(bg_color, fg_color, alpha)
    # Extract RGB components
    bg_r = (bg_color >> 24) & 0xff
    bg_g = (bg_color >> 16) & 0xff  
    bg_b = (bg_color >> 8) & 0xff
    
    fg_r = (fg_color >> 24) & 0xff
    fg_g = (fg_color >> 16) & 0xff
    fg_b = (fg_color >> 8) & 0xff
    
    # Blend
    r = (bg_r + (fg_r - bg_r) * alpha).to_i
    g = (bg_g + (fg_g - bg_g) * alpha).to_i
    b = (bg_b + (fg_b - bg_b) * alpha).to_i
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  def add_center_logo(png, total_size)
    center_x = total_size / 2
    center_y = total_size / 2
    logo_size = options[:logo_size]
    radius = logo_size / 2
    
    # Create smooth circular background
    (-radius..radius).each do |x|
      (-radius..radius).each do |y|
        distance = Math.sqrt(x * x + y * y)
        
        if distance <= radius
          # Solid background
          png[center_x + x, center_y + y] = options[:logo_background_color]
        elsif distance <= radius + 2
          # Anti-aliased edge
          alpha = 1.0 - ((distance - radius) / 2.0)
          blended = blend_colors(options[:foreground_color], options[:logo_background_color], alpha)
          png[center_x + x, center_y + y] = blended
        end
      end
    end
    
    # Draw refined paper plane icon
    draw_refined_paper_plane(png, center_x, center_y, logo_size)
  end

  def draw_refined_paper_plane(png, center_x, center_y, size)
    icon_color = ChunkyPNG::Color::WHITE
    icon_size = size * 0.4
    
    # More detailed paper plane
    points = [
      # Main triangle (paper plane body)
      [-icon_size * 0.8, 0],
      [icon_size * 0.3, -icon_size * 0.4],
      [icon_size * 0.3, icon_size * 0.4],
      
      # Wing details
      [-icon_size * 0.3, -icon_size * 0.2],
      [icon_size * 0.1, -icon_size * 0.3],
      [-icon_size * 0.3, icon_size * 0.2],
      [icon_size * 0.1, icon_size * 0.3]
    ]
    
    # Draw smooth lines for paper plane
    points.each_with_index do |point, i|
      next_point = points[(i + 1) % 3] # Connect first 3 points for main triangle
      draw_smooth_line(png, 
        center_x + point[0], center_y + point[1],
        center_x + next_point[0], center_y + next_point[1],
        icon_color, 2)
    end
    
    # Add center dot
    draw_circular_module(png, center_x - 1, center_y - 1, 3, 1.0)
  end

  def draw_smooth_line(png, x1, y1, x2, y2, color, thickness = 1)
    # Bresenham's line algorithm with thickness
    dx = (x2 - x1).abs
    dy = (y2 - y1).abs
    x, y = x1, y1
    x_inc = x1 < x2 ? 1 : -1
    y_inc = y1 < y2 ? 1 : -1
    error = dx - dy

    while true
      # Draw thick point
      (-thickness..thickness).each do |tx|
        (-thickness..thickness).each do |ty|
          if Math.sqrt(tx*tx + ty*ty) <= thickness
            safe_set_pixel(png, x + tx, y + ty, color)
          end
        end
      end

      break if x == x2 && y == y2

      e2 = 2 * error
      if e2 > -dy
        error -= dy
        x += x_inc
      end
      if e2 < dx
        error += dx
        y += y_inc
      end
    end
  end

  def safe_set_pixel(png, x, y, color)
    return unless x.between?(0, png.width - 1) && y.between?(0, png.height - 1)
    png[x, y] = color
  end

  def apply_smooth_gradient_effect(png)
    # Enhanced gradient with smooth color transitions
    width = png.width
    height = png.height
    
    # Create radial gradient from center
    center_x = width / 2.0
    center_y = height / 2.0
    max_distance = Math.sqrt(center_x**2 + center_y**2)
    
    width.times do |x|
      height.times do |y|
        current_pixel = png[x, y]
        next if current_pixel == options[:background_color]
        
        # Calculate distance from center for radial gradient
        distance = Math.sqrt((x - center_x)**2 + (y - center_y)**2)
        ratio = [distance / max_distance, 1.0].min
        
        # Apply smooth color interpolation
        new_color = interpolate_color_smooth(
          options[:gradient_start], 
          options[:gradient_end], 
          ratio
        )
        png[x, y] = new_color
      end
    end
  end

  def interpolate_color_smooth(color1, color2, ratio)
    # Smooth color interpolation with easing
    eased_ratio = ease_in_out_cubic(ratio)
    
    r1, g1, b1 = extract_rgb(color1)
    r2, g2, b2 = extract_rgb(color2)
    
    r = (r1 + (r2 - r1) * eased_ratio).to_i.clamp(0, 255)
    g = (g1 + (g2 - g1) * eased_ratio).to_i.clamp(0, 255)
    b = (b1 + (b2 - b1) * eased_ratio).to_i.clamp(0, 255)
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  def extract_rgb(color)
    [(color >> 24) & 0xff, (color >> 16) & 0xff, (color >> 8) & 0xff]
  end

  def ease_in_out_cubic(t)
    t < 0.5 ? 4 * t * t * t : 1 - ((-2 * t + 2) ** 3) / 2
  end

  def create_styled_png(qrcode)
    # Redirect to new smooth method
    create_smooth_styled_png(qrcode)
  end

  # Updated default options for smooth, circular design
  def default_options
    {
      module_size: 12,           # Larger modules for smoother circles
      border_size: 24,           # More border for clean look
      corner_radius: 8,          # High corner radius for circular effect
      qr_size: 6,               # Good balance of size vs density
      background_color: ChunkyPNG::Color::WHITE,
      foreground_color: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      data_type: :url,
      center_logo: true,
      logo_size: 36,            # Slightly larger logo
      logo_color: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      logo_background_color: ChunkyPNG::Color::WHITE,
      gradient: true,           # Enable gradient for stunning effect
      gradient_start: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      gradient_end: ChunkyPNG::Color.rgb(59, 130, 246),   # Blue
      finder_roundness: 0.9,    # Very round finder patterns
      module_roundness: 0.7,    # Moderately round data modules
      anti_aliasing: true       # Smooth edges
    }
  end
end