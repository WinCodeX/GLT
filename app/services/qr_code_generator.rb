# =====================================================
# ENHANCED: app/services/qr_code_generator.rb - Fast Organic QR Codes
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
    
    # Create organic styled PNG (fast approach)
    create_fast_organic_png(qrcode)
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

  # ENHANCED: Fast organic QR generation
  def create_fast_organic_png(qrcode)
    # Keep original dimensions for speed
    module_size = options[:module_size]
    border_size = options[:border_size]
    qr_modules = qrcode.modules.size
    
    total_size = (qr_modules * module_size) + (border_size * 2)
    
    Rails.logger.info "🌊 Creating fast organic QR: #{total_size}x#{total_size}, modules: #{qr_modules}"
    
    # Create canvas
    png = ChunkyPNG::Image.new(total_size, total_size, options[:background_color])
    
    # First pass: Draw base modules with enhanced organic connections
    qrcode.modules.each_with_index do |row, row_index|
      row.each_with_index do |module_dark, col_index|
        next unless module_dark
        
        x = border_size + (col_index * module_size)
        y = border_size + (row_index * module_size)
        
        # Skip finder patterns - handle them separately
        next if is_finder_pattern?(row_index, col_index, qr_modules)
        
        # Enhanced organic module rendering
        draw_organic_module(png, qrcode.modules, row_index, col_index, x, y, module_size)
      end
    end
    
    # Draw enhanced organic finder patterns
    draw_organic_finder_patterns(png, qrcode.modules, module_size, border_size)
    
    # Apply enhanced diagonal gradient
    if options[:gradient]
      apply_enhanced_gradient_effect(png)
    end
    
    # Add refined center logo
    if options[:center_logo]
      add_enhanced_center_logo(png, total_size)
    end
    
    Rails.logger.info "✅ Fast organic QR created successfully"
    png.to_blob
  end

  # ENHANCED: Draw organic modules that flow together
  def draw_organic_module(png, modules, row, col, x, y, size)
    # Analyze connections for organic shape
    connections = analyze_module_connections(modules, row, col)
    
    # Choose organic shape based on connections
    case connections[:pattern]
    when :isolated
      draw_organic_circle(png, x, y, size, 0.9) # Almost full circle
    when :end_piece
      draw_organic_pill(png, x, y, size, connections[:direction])
    when :corner
      draw_organic_corner_piece(png, x, y, size, connections[:corner_type])
    when :straight
      draw_organic_rectangle(png, x, y, size, connections[:direction])
    when :junction
      draw_organic_junction(png, x, y, size, connections[:arms])
    else
      draw_organic_blob(png, x, y, size, connections)
    end
  end

  # ENHANCED: Fast connection analysis
  def analyze_module_connections(modules, row, col)
    # Check 4 cardinal directions quickly
    neighbors = {
      top: (row > 0 && modules[row - 1][col]),
      bottom: (row < modules.size - 1 && modules[row + 1][col]),
      left: (col > 0 && modules[row][col - 1]),
      right: (col < modules[row].size - 1 && modules[row][col + 1])
    }
    
    connected_sides = neighbors.values.count(true)
    
    # Determine organic pattern type
    pattern = case connected_sides
    when 0
      :isolated
    when 1
      :end_piece
    when 2
      # Check if it's a corner or straight line
      if (neighbors[:top] && neighbors[:bottom]) || (neighbors[:left] && neighbors[:right])
        :straight
      else
        :corner
      end
    when 3
      :junction
    else
      :connected
    end
    
    {
      pattern: pattern,
      neighbors: neighbors,
      direction: determine_primary_direction(neighbors),
      corner_type: determine_corner_type(neighbors),
      arms: neighbors.keys.select { |k| neighbors[k] }
    }
  end

  def determine_primary_direction(neighbors)
    return :vertical if neighbors[:top] || neighbors[:bottom]
    return :horizontal if neighbors[:left] || neighbors[:right]
    :none
  end

  def determine_corner_type(neighbors)
    return :top_left if neighbors[:bottom] && neighbors[:right]
    return :top_right if neighbors[:bottom] && neighbors[:left]
    return :bottom_left if neighbors[:top] && neighbors[:right]
    return :bottom_right if neighbors[:top] && neighbors[:left]
    :none
  end

  # ENHANCED: Organic shape drawing methods
  def draw_organic_circle(png, x, y, size, roundness)
    center_x = x + size / 2.0
    center_y = y + size / 2.0
    radius = size * roundness / 2.0
    
    # Draw anti-aliased circle
    (0...size).each do |dx|
      (0...size).each do |dy|
        pixel_x = x + dx
        pixel_y = y + dy
        
        distance = Math.sqrt((dx - size/2.0)**2 + (dy - size/2.0)**2)
        
        if distance <= radius + 0.5
          alpha = distance <= radius ? 1.0 : (radius + 0.5 - distance) * 2
          alpha = [alpha, 0.0].max
          
          blended_color = blend_pixel_colors(png[pixel_x, pixel_y], options[:foreground_color], alpha)
          png[pixel_x, pixel_y] = blended_color
        end
      end
    end
  end

  def draw_organic_pill(png, x, y, size, direction)
    if direction == :vertical
      # Vertical pill shape
      draw_organic_circle(png, x, y, size, 0.7)
      png.rect(x + size/4, y, x + 3*size/4, y + size, options[:foreground_color], options[:foreground_color])
    else
      # Horizontal pill shape  
      draw_organic_circle(png, x, y, size, 0.7)
      png.rect(x, y + size/4, x + size, y + 3*size/4, options[:foreground_color], options[:foreground_color])
    end
  end

  def draw_organic_corner_piece(png, x, y, size, corner_type)
    # Draw organic corner with flowing curves
    base_radius = size * 0.4
    
    case corner_type
    when :top_left
      # Draw flowing corner from top to left
      draw_organic_quarter_circle(png, x + size, y + size, size, :top_left)
    when :top_right
      draw_organic_quarter_circle(png, x, y + size, size, :top_right)
    when :bottom_left
      draw_organic_quarter_circle(png, x + size, y, size, :bottom_left)
    when :bottom_right
      draw_organic_quarter_circle(png, x, y, size, :bottom_right)
    else
      draw_organic_blob(png, x, y, size, {})
    end
  end

  def draw_organic_quarter_circle(png, cx, cy, radius, quadrant)
    # Draw flowing quarter circle
    (0..radius).each do |i|
      (0..radius).each do |j|
        distance = Math.sqrt(i * i + j * j)
        next if distance > radius
        
        # Enhanced organic curve
        alpha = distance <= radius * 0.8 ? 1.0 : (1.0 - (distance - radius * 0.8) / (radius * 0.2))
        alpha = [alpha, 0.0].max
        
        case quadrant
        when :top_left
          plot_x, plot_y = cx - i, cy - j
        when :top_right
          plot_x, plot_y = cx + i, cy - j
        when :bottom_left
          plot_x, plot_y = cx - i, cy + j
        when :bottom_right
          plot_x, plot_y = cx + i, cy + j
        end
        
        next if plot_x < 0 || plot_x >= png.width || plot_y < 0 || plot_y >= png.height
        
        if alpha > 0
          blended_color = blend_pixel_colors(png[plot_x, plot_y], options[:foreground_color], alpha)
          png[plot_x, plot_y] = blended_color
        end
      end
    end
  end

  def draw_organic_rectangle(png, x, y, size, direction)
    # Draw flowing rectangle with organic ends
    if direction == :vertical
      # Vertical flow with rounded ends
      png.rect(x, y + size/6, x + size, y + 5*size/6, options[:foreground_color], options[:foreground_color])
      draw_organic_circle(png, x, y, size/3*2, 1.0) # Rounded top
      draw_organic_circle(png, x, y + size/3, size/3*2, 1.0) # Rounded bottom
    else
      # Horizontal flow with rounded ends
      png.rect(x + size/6, y, x + 5*size/6, y + size, options[:foreground_color], options[:foreground_color])
      draw_organic_circle(png, x, y, size/3*2, 1.0) # Rounded left
      draw_organic_circle(png, x + size/3, y, size/3*2, 1.0) # Rounded right
    end
  end

  def draw_organic_junction(png, x, y, size, arms)
    # Draw organic junction with flowing arms
    center_radius = size * 0.3
    draw_organic_circle(png, x + size/2 - center_radius/2, y + size/2 - center_radius/2, center_radius, 1.0)
    
    # Extend arms organically
    arms.each do |direction|
      case direction
      when :top
        png.rect(x + size/3, y, x + 2*size/3, y + size/2, options[:foreground_color], options[:foreground_color])
      when :bottom
        png.rect(x + size/3, y + size/2, x + 2*size/3, y + size, options[:foreground_color], options[:foreground_color])
      when :left
        png.rect(x, y + size/3, x + size/2, y + 2*size/3, options[:foreground_color], options[:foreground_color])
      when :right
        png.rect(x + size/2, y + size/3, x + size, y + 2*size/3, options[:foreground_color], options[:foreground_color])
      end
    end
  end

  def draw_organic_blob(png, x, y, size, connections)
    # Default organic blob shape
    # Draw slightly larger rounded rectangle for flowing appearance
    organic_radius = size * 0.3
    draw_enhanced_rounded_rect(png, x, y, size, size, organic_radius)
  end

  # ENHANCED: Better rounded rectangle with organic flow
  def draw_enhanced_rounded_rect(png, x, y, width, height, radius)
    color = options[:foreground_color]
    
    # Draw main body
    png.rect(x + radius, y, x + width - radius, y + height, color, color)
    png.rect(x, y + radius, x + width, y + height - radius, color, color)
    
    # Draw organic corners with better smoothing
    draw_enhanced_organic_corner(png, x + radius, y + radius, radius, :top_left, color)
    draw_enhanced_organic_corner(png, x + width - radius, y + radius, radius, :top_right, color)
    draw_enhanced_organic_corner(png, x + radius, y + height - radius, radius, :bottom_left, color)
    draw_enhanced_organic_corner(png, x + width - radius, y + height - radius, radius, :bottom_right, color)
  end

  # ENHANCED: Organic corners with smooth anti-aliasing
  def draw_enhanced_organic_corner(png, cx, cy, radius, corner, color)
    # Enhanced corner with organic smoothing and anti-aliasing
    organic_factor = 1.2 # Makes corners more organic
    
    (-radius..radius).each do |i|
      (-radius..radius).each do |j|
        distance = Math.sqrt(i * i + j * j)
        next if distance > radius * organic_factor
        
        # Calculate organic alpha with smooth falloff
        alpha = if distance <= radius
          1.0
        else
          # Smooth organic falloff
          falloff_distance = distance - radius
          max_falloff = radius * (organic_factor - 1.0)
          1.0 - (falloff_distance / max_falloff) ** 1.5 # Organic curve
        end
        
        alpha = [alpha, 0.0].max
        next if alpha <= 0.1
        
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
        
        next if plot_x < 0 || plot_x >= png.width || plot_y < 0 || plot_y >= png.height
        
        # Blend with existing pixel for organic appearance
        existing_color = png[plot_x, plot_y]
        blended_color = blend_pixel_colors(existing_color, color, alpha)
        png[plot_x, plot_y] = blended_color
      end
    end
  end

  # ENHANCED: Organic finder patterns with flowing appearance
  def draw_organic_finder_patterns(png, modules, module_size, border_size)
    finder_positions = [
      [0, 0],                           # Top-left
      [0, modules.size - 7],           # Top-right  
      [modules.size - 7, 0]            # Bottom-left
    ]
    
    finder_positions.each do |start_row, start_col|
      x = border_size + (start_col * module_size)
      y = border_size + (start_row * module_size)
      
      # Organic finder pattern with flowing rounded rectangles
      outer_size = 7 * module_size
      outer_radius = module_size * 1.8 # Large organic radius
      
      # Outer flowing square
      draw_enhanced_rounded_rect(png, x, y, outer_size, outer_size, outer_radius)
      
      # Inner white space with organic curves
      inner_x = x + module_size
      inner_y = y + module_size  
      inner_size = 5 * module_size
      inner_radius = module_size * 1.3
      draw_enhanced_rounded_rect(png, inner_x, inner_y, inner_size, inner_size, inner_radius, options[:background_color])
      
      # Center organic square
      center_x = x + 2 * module_size
      center_y = y + 2 * module_size
      center_size = 3 * module_size
      center_radius = module_size * 0.9
      draw_enhanced_rounded_rect(png, center_x, center_y, center_size, center_size, center_radius)
    end
  end

  # Overloaded method for custom color
  def draw_enhanced_rounded_rect(png, x, y, width, height, radius, custom_color = nil)
    color = custom_color || options[:foreground_color]
    
    # Draw main body
    png.rect(x + radius, y, x + width - radius, y + height, color, color)
    png.rect(x, y + radius, x + width, y + height - radius, color, color)
    
    # Draw organic corners
    draw_enhanced_organic_corner(png, x + radius, y + radius, radius, :top_left, color)
    draw_enhanced_organic_corner(png, x + width - radius, y + radius, radius, :top_right, color)
    draw_enhanced_organic_corner(png, x + radius, y + height - radius, radius, :bottom_left, color)
    draw_enhanced_organic_corner(png, x + width - radius, y + height - radius, radius, :bottom_right, color)
  end

  # ENHANCED: Diagonal gradient like in reference image
  def apply_enhanced_gradient_effect(png)
    width = png.width
    height = png.height
    
    # Create diagonal gradient from top-left to bottom-right
    width.times do |x|
      height.times do |y|
        current_pixel = png[x, y]
        next if current_pixel == options[:background_color]
        
        # Diagonal gradient calculation (like reference image)
        diagonal_progress = (x + y) / (width + height).to_f
        
        # Apply organic curve to gradient for smoother transition
        curved_progress = diagonal_progress ** 0.9 # Slight organic curve
        
        # Smooth color interpolation
        new_color = interpolate_color_enhanced(options[:gradient_start], options[:gradient_end], curved_progress)
        png[x, y] = new_color
      end
    end
  end

  # ENHANCED: Better color interpolation
  def interpolate_color_enhanced(color1, color2, ratio)
    # Clamp ratio
    ratio = [[ratio, 0.0].max, 1.0].min
    
    # Extract RGB components
    r1, g1, b1 = [(color1 >> 24) & 0xff, (color1 >> 16) & 0xff, (color1 >> 8) & 0xff]
    r2, g2, b2 = [(color2 >> 24) & 0xff, (color2 >> 16) & 0xff, (color2 >> 8) & 0xff]
    
    # Enhanced interpolation with slight organic curve
    organic_ratio = ratio ** 1.1 # Subtle organic progression
    
    r = (r1 + (r2 - r1) * organic_ratio).round
    g = (g1 + (g2 - g1) * organic_ratio).round
    b = (b1 + (b2 - b1) * organic_ratio).round
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  # ENHANCED: Organic center logo
  def add_enhanced_center_logo(png, total_size)
    center_x = total_size / 2
    center_y = total_size / 2
    logo_size = options[:logo_size]
    
    # Organic circular background with smooth edges
    logo_radius = logo_size / 2
    organic_expansion = 1.3
    
    (-logo_radius * organic_expansion).round.upto((logo_radius * organic_expansion).round) do |x|
      (-logo_radius * organic_expansion).round.upto((logo_radius * organic_expansion).round) do |y|
        distance = Math.sqrt(x * x + y * y)
        
        if distance <= logo_radius * organic_expansion
          # Organic alpha calculation
          alpha = if distance <= logo_radius * 0.7
            0.9 # Solid center
          else
            # Smooth organic falloff
            falloff = (distance - logo_radius * 0.7) / (logo_radius * (organic_expansion - 0.7))
            0.9 * (1.0 - falloff ** 1.8) # Organic curve
          end
          
          alpha = [alpha, 0.0].max
          
          if alpha > 0.1
            logo_color = ChunkyPNG::Color.rgba(124, 58, 237, (alpha * 255).round)
            plot_x = center_x + x
            plot_y = center_y + y
            
            next if plot_x < 0 || plot_x >= png.width || plot_y < 0 || plot_y >= png.height
            
            existing_color = png[plot_x, plot_y]
            blended_color = blend_pixel_colors(existing_color, logo_color, alpha)
            png[plot_x, plot_y] = blended_color
          end
        end
      end
    end
    
    # Draw organic paper plane icon
    draw_organic_paper_plane(png, center_x, center_y, logo_size)
  end

  # ENHANCED: Organic paper plane with flowing design
  def draw_organic_paper_plane(png, center_x, center_y, size)
    icon_color = ChunkyPNG::Color::WHITE
    icon_size = size * 0.4
    
    # Main triangle with organic curves
    main_points = [
      [center_x - icon_size * 0.35, center_y - icon_size * 0.4],
      [center_x + icon_size * 0.45, center_y],
      [center_x - icon_size * 0.35, center_y + icon_size * 0.4],
      [center_x - icon_size * 0.1, center_y]
    ]
    
    fill_organic_polygon(png, main_points, icon_color)
    
    # Wing detail with organic flow
    wing_points = [
      [center_x - icon_size * 0.1, center_y - icon_size * 0.2],
      [center_x + icon_size * 0.12, center_y - icon_size * 0.28],
      [center_x + icon_size * 0.2, center_y - icon_size * 0.08],
      [center_x, center_y]
    ]
    
    fill_organic_polygon(png, wing_points, icon_color)
  end

  # ENHANCED: Fast organic polygon filling
  def fill_organic_polygon(png, points, color)
    return if points.length < 3
    
    min_x = points.map { |p| p[0] }.min.round
    max_x = points.map { |p| p[0] }.max.round  
    min_y = points.map { |p| p[1] }.min.round
    max_y = points.map { |p| p[1] }.max.round
    
    (min_x..max_x).each do |x|
      (min_y..max_y).each do |y|
        next if x < 0 || x >= png.width || y < 0 || y >= png.height
        
        if point_in_polygon_fast?(x, y, points)
          png[x, y] = color
        end
      end
    end
  end

  # Fast point-in-polygon test
  def point_in_polygon_fast?(x, y, points)
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

  # Fast pixel color blending
  def blend_pixel_colors(background, foreground, alpha)
    return background if alpha <= 0.0
    return foreground if alpha >= 1.0
    
    # Extract RGB components
    bg_r = (background >> 24) & 0xff
    bg_g = (background >> 16) & 0xff  
    bg_b = (background >> 8) & 0xff
    
    fg_r = (foreground >> 24) & 0xff
    fg_g = (foreground >> 16) & 0xff
    fg_b = (foreground >> 8) & 0xff
    
    # Fast blending
    r = (bg_r + (fg_r - bg_r) * alpha).round
    g = (bg_g + (fg_g - bg_g) * alpha).round
    b = (bg_b + (fg_b - bg_b) * alpha).round
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  # Check if position is in finder pattern
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

  # Keep existing methods for compatibility
  def calculate_corner_radius(modules, row, col)
    max_radius = options[:corner_radius]
    return 0 if max_radius == 0
    
    # Enhanced organic rounding
    neighbors = {
      top: row > 0 ? modules[row - 1][col] : false,
      bottom: row < modules.size - 1 ? modules[row + 1][col] : false,
      left: col > 0 ? modules[row][col - 1] : false,
      right: col < modules[row].size - 1 ? modules[row][col + 1] : false,
    }
    
    connected_sides = neighbors.values.count(true)
    
    # More aggressive rounding for organic look
    case connected_sides
    when 0 then max_radius * 1.2 # Isolated modules = very round
    when 1 then max_radius * 1.0 # End pieces = full rounding
    when 2 then max_radius * 0.8 # Corners = good rounding
    when 3 then max_radius * 0.6 # Junctions = medium rounding
    else max_radius * 0.3 # Connected = slight rounding
    end.to_i
  end

  def draw_rounded_module(png, x, y, size, radius)
    draw_enhanced_rounded_rect(png, x, y, size, size, radius)
  end

  def draw_square_module(png, x, y, size)
    # Even "square" modules get slight organic rounding
    organic_radius = size * 0.15
    draw_enhanced_rounded_rect(png, x, y, size, size, organic_radius)
  end

  def add_center_logo(png, total_size)
    add_enhanced_center_logo(png, total_size)
  end

  def apply_gradient_effect(png)
    apply_enhanced_gradient_effect(png)
  end

  def interpolate_color(color1, color2, ratio)
    interpolate_color_enhanced(color1, color2, ratio)
  end

  def default_options
    {
      module_size: 8,
      border_size: 20,
      corner_radius: 6,            # Increased for more organic appearance
      qr_size: 6,
      background_color: ChunkyPNG::Color::WHITE,
      foreground_color: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      data_type: :url,
      center_logo: true,
      logo_size: 30,
      logo_color: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      gradient: true,              # Enable gradient for organic look
      gradient_start: ChunkyPNG::Color.rgb(124, 58, 237), # Purple (#7c3aed)
      gradient_end: ChunkyPNG::Color.rgb(59, 130, 246)    # Blue (#3b82f6)
    }
  end
end