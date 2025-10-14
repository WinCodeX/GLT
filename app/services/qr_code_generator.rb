# app/services/qr_code_generator.rb
# FIXED: Generates QR codes with correct public tracking URL and company logo

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
    
    # Create styled PNG
    create_styled_png(qrcode)
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
      # Try multiple sources for the base URL in order of preference
      base_url = nil
      
      # 1. Try APP_BASE_URL environment variable (Render.com)
      if ENV['APP_BASE_URL'].present?
        base_url = ENV['APP_BASE_URL'].sub(/\/$/, '') # Remove trailing slash if present
      end
      
      # 2. Try action_mailer configuration
      if base_url.nil? && Rails.application.config.action_mailer.default_url_options[:host].present?
        host = Rails.application.config.action_mailer.default_url_options[:host]
        protocol = Rails.env.production? ? 'https' : 'http'
        base_url = "#{protocol}://#{host}"
      end
      
      # 3. Try APP_URL environment variable (alternative)
      if base_url.nil? && ENV['APP_URL'].present?
        base_url = ENV['APP_URL'].sub(/\/$/, '')
      end
      
      # 4. Try RENDER_EXTERNAL_URL for Render.com deployments
      if base_url.nil? && ENV['RENDER_EXTERNAL_URL'].present?
        base_url = ENV['RENDER_EXTERNAL_URL'].sub(/\/$/, '')
      end
      
      # 5. Try to detect from Rails configuration
      if base_url.nil? && defined?(Rails.application.routes.default_url_options[:host])
        host = Rails.application.routes.default_url_options[:host]
        protocol = Rails.env.production? ? 'https' : 'http'
        base_url = "#{protocol}://#{host}"
      end
      
      # 6. Fallback defaults
      if base_url.nil?
        base_url = if Rails.env.production?
          'https://glt-53x8.onrender.com' # Production default
        else
          'http://localhost:3000' # Development default
        end
      end
      
      # FIXED: Use /public/track/ instead of /track/
      "#{base_url}/public/track/#{package.code}"
      
    rescue => e
      Rails.logger.warn "URL generation fallback triggered: #{e.message}"
      # FIXED: Fallback also uses /public/track/
      "/public/track/#{package.code}"
    end
  end

  def create_styled_png(qrcode)
    # Calculate dimensions - keep original for speed
    module_size = options[:module_size]
    border_size = options[:border_size]
    qr_modules = qrcode.modules.size
    
    total_size = (qr_modules * module_size) + (border_size * 2)
    
    Rails.logger.info "🎨 Creating PNG: #{total_size}x#{total_size}, modules: #{qr_modules}"
    
    # Create canvas
    png = ChunkyPNG::Image.new(total_size, total_size, options[:background_color])
    
    # Draw QR code with enhanced organic appearance
    qrcode.modules.each_with_index do |row, row_index|
      row.each_with_index do |module_dark, col_index|
        next unless module_dark
        
        x = border_size + (col_index * module_size)
        y = border_size + (row_index * module_size)
        
        # Skip finder patterns - handle them separately for organic look
        if is_finder_pattern?(row_index, col_index, qr_modules)
          # Finder patterns handled separately
          next
        end
        
        # Enhanced organic corner calculation
        corner_radius = calculate_organic_corner_radius(qrcode.modules, row_index, col_index)
        
        if corner_radius > 0
          draw_organic_rounded_module(png, x, y, module_size, corner_radius)
        else
          draw_organic_square_module(png, x, y, module_size)
        end
      end
    end
    
    # Draw organic finder patterns separately
    draw_organic_finder_patterns(png, qr_modules, module_size, border_size)
    
    # Add enhanced gradient effect BEFORE logo so it doesn't overwrite it
    if options[:gradient]
      apply_organic_gradient_effect(png)
    end
    
    # Add center logo if specified (AFTER gradient)
    if options[:center_logo]
      add_center_logo(png, total_size)
    end
    
    Rails.logger.info "✅ PNG created successfully"
    png.to_blob
  end

  # ENHANCED: Better organic corner radius calculation
  def calculate_organic_corner_radius(modules, row, col)
    max_radius = options[:corner_radius]
    return 0 if max_radius == 0
    
    # Check surrounding modules
    neighbors = {
      top: row > 0 ? modules[row - 1][col] : false,
      bottom: row < modules.size - 1 ? modules[row + 1][col] : false,
      left: col > 0 ? modules[row][col - 1] : false,
      right: col < modules[row].size - 1 ? modules[row][col + 1] : false,
    }
    
    connected_sides = neighbors.values.count(true)
    
    # Enhanced organic rounding - more aggressive for flowing look
    case connected_sides
    when 0 then (max_radius * 2.0).to_i    # Isolated = almost circular
    when 1 then (max_radius * 1.5).to_i    # End pieces = very round
    when 2 then (max_radius * 1.2).to_i    # Corners = good rounding
    when 3 then (max_radius * 0.8).to_i    # Junctions = medium rounding
    else (max_radius * 0.5).to_i           # Connected = slight rounding
    end
  end

  # ENHANCED: Organic rounded module with better smoothing
  def draw_organic_rounded_module(png, x, y, size, radius)
    color = options[:foreground_color]
    
    # Clamp radius to prevent over-rounding
    radius = [radius, size / 2].min
    
    # Draw main rectangle body
    if radius > 0
      png.rect(x + radius, y, x + size - radius - 1, y + size - 1, color, color)
      png.rect(x, y + radius, x + size - 1, y + size - radius - 1, color, color)
      
      # Draw organic corners with enhanced smoothing
      draw_organic_corner(png, x + radius, y + radius, radius, :top_left, color)
      draw_organic_corner(png, x + size - radius - 1, y + radius, radius, :top_right, color)
      draw_organic_corner(png, x + radius, y + size - radius - 1, radius, :bottom_left, color)
      draw_organic_corner(png, x + size - radius - 1, y + size - radius - 1, radius, :bottom_right, color)
    else
      # Fallback to simple rectangle
      png.rect(x, y, x + size - 1, y + size - 1, color, color)
    end
  end

  # ENHANCED: Organic corners with smooth anti-aliasing
  def draw_organic_corner(png, cx, cy, radius, corner, color)
    # Enhanced organic corner with smooth falloff
    organic_factor = 1.3 # Makes corners more flowing
    
    (0..(radius * organic_factor).to_i).each do |i|
      (0..(radius * organic_factor).to_i).each do |j|
        distance = Math.sqrt(i * i + j * j)
        next if distance > radius * organic_factor
        
        # Calculate alpha for organic smoothness
        alpha = if distance <= radius
          1.0
        else
          # Smooth organic falloff
          falloff_distance = distance - radius
          max_falloff = radius * (organic_factor - 1.0)
          1.0 - (falloff_distance / max_falloff)
        end
        
        alpha = [alpha, 0.0].max
        next if alpha < 0.1
        
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
        
        # Blend colors for organic appearance
        if alpha >= 0.9
          png[plot_x, plot_y] = color
        else
          existing_color = png[plot_x, plot_y]
          blended_color = blend_colors_simple(existing_color, color, alpha)
          png[plot_x, plot_y] = blended_color
        end
      end
    end
  end

  # ENHANCED: Organic square modules (slight rounding even for "square" modules)
  def draw_organic_square_module(png, x, y, size)
    # Even square modules get slight organic rounding
    organic_radius = [size / 6, 2].max # Minimum organic rounding
    draw_organic_rounded_module(png, x, y, size, organic_radius)
  end

  # ENHANCED: Organic finder patterns like in reference image
  def draw_organic_finder_patterns(png, qr_size, module_size, border_size)
    finder_positions = [
      [0, 0],                    # Top-left
      [0, qr_size - 7],         # Top-right  
      [qr_size - 7, 0]          # Bottom-left
    ]
    
    finder_positions.each do |start_row, start_col|
      x = border_size + (start_col * module_size)
      y = border_size + (start_row * module_size)
      
      # Draw organic finder pattern (7x7)
      outer_size = 7 * module_size
      outer_radius = (module_size * 2.5).to_i # Large organic radius
      
      # Outer flowing square
      draw_organic_rounded_rect(png, x, y, outer_size, outer_size, outer_radius, options[:foreground_color])
      
      # Inner white space with organic curves
      inner_x = x + module_size
      inner_y = y + module_size  
      inner_size = 5 * module_size
      inner_radius = (module_size * 1.8).to_i
      draw_organic_rounded_rect(png, inner_x, inner_y, inner_size, inner_size, inner_radius, options[:background_color])
      
      # Center organic square
      center_x = x + 2 * module_size
      center_y = y + 2 * module_size
      center_size = 3 * module_size
      center_radius = (module_size * 1.2).to_i
      draw_organic_rounded_rect(png, center_x, center_y, center_size, center_size, center_radius, options[:foreground_color])
    end
  end

  # ENHANCED: Organic rounded rectangle
  def draw_organic_rounded_rect(png, x, y, width, height, radius, color)
    # Clamp radius
    radius = [radius, [width, height].min / 2].min
    
    # Draw main body
    png.rect(x + radius, y, x + width - radius - 1, y + height - 1, color, color)
    png.rect(x, y + radius, x + width - 1, y + height - radius - 1, color, color)
    
    # Draw organic corners
    draw_organic_corner(png, x + radius, y + radius, radius, :top_left, color)
    draw_organic_corner(png, x + width - radius - 1, y + radius, radius, :top_right, color)
    draw_organic_corner(png, x + radius, y + height - radius - 1, radius, :bottom_left, color)
    draw_organic_corner(png, x + width - radius - 1, y + height - radius - 1, radius, :bottom_right, color)
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

  # ENHANCED: Better gradient effect
  def apply_organic_gradient_effect(png)
    width = png.width
    height = png.height
    
    # Create diagonal gradient like in reference image
    width.times do |x|
      height.times do |y|
        current_pixel = png[x, y]
        next if current_pixel == options[:background_color]
        
        # Diagonal gradient calculation
        ratio = (x + y) / (width + height).to_f
        ratio = [ratio, 1.0].min
        
        # Apply organic curve to gradient
        curved_ratio = ratio ** 0.9 # Slight curve for organic feel
        
        # Interpolate colors
        new_color = interpolate_color_organic(options[:gradient_start], options[:gradient_end], curved_ratio)
        png[x, y] = new_color
      end
    end
  end

  # ENHANCED: Organic color interpolation
  def interpolate_color_organic(color1, color2, ratio)
    # Extract RGB components
    r1, g1, b1 = [(color1 >> 24) & 0xff, (color1 >> 16) & 0xff, (color1 >> 8) & 0xff]
    r2, g2, b2 = [(color2 >> 24) & 0xff, (color2 >> 16) & 0xff, (color2 >> 8) & 0xff]
    
    # Smooth interpolation
    r = (r1 + (r2 - r1) * ratio).round
    g = (g1 + (g2 - g1) * ratio).round
    b = (b1 + (b2 - b1) * ratio).round
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  # Simple color blending
  def blend_colors_simple(background, foreground, alpha)
    return background if alpha <= 0.0
    return foreground if alpha >= 1.0
    
    # Extract RGB components
    bg_r = (background >> 24) & 0xff
    bg_g = (background >> 16) & 0xff  
    bg_b = (background >> 8) & 0xff
    
    fg_r = (foreground >> 24) & 0xff
    fg_g = (foreground >> 16) & 0xff
    fg_b = (foreground >> 8) & 0xff
    
    # Simple blending
    r = (bg_r + (fg_r - bg_r) * alpha).round
    g = (bg_g + (fg_g - bg_g) * alpha).round
    b = (bg_b + (fg_b - bg_b) * alpha).round
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  # MODIFIED: Load actual logo.png and render as circular with zoom
  def add_center_logo(png, total_size)
    begin
      # Try to load logo from multiple possible paths
      logo_paths = [
        Rails.root.join('app', 'assets', 'images', 'logo.png'),
        Rails.root.join('public', 'images', 'logo.png'),
        Rails.root.join('public', 'logo.png'),
        Rails.root.join('app', 'assets', 'images', 'logos', 'logo.png')
      ]
      
      logo_path = logo_paths.find { |path| File.exist?(path) }
      
      unless logo_path
        Rails.logger.error "❌ Logo file not found! Searched in:"
        logo_paths.each { |path| Rails.logger.error "  - #{path}" }
        return
      end
      
      Rails.logger.info "📷 Loading logo from: #{logo_path}"
      
      # Load logo image
      logo = ChunkyPNG::Image.from_file(logo_path)
      Rails.logger.info "📏 Logo dimensions: #{logo.width}x#{logo.height}"
      
      # Calculate center position and size
      center_x = total_size / 2
      center_y = total_size / 2
      logo_size = options[:logo_size]
      zoom_factor = options[:logo_zoom] # Zoom in on the logo
      
      Rails.logger.info "🎯 Center: (#{center_x}, #{center_y}), Logo size: #{logo_size}, Zoom: #{zoom_factor}"
      
      # Calculate zoomed dimensions
      zoomed_size = (logo_size * zoom_factor).to_i
      
      # Calculate source crop area (center of logo, zoomed)
      src_size = (logo.width.to_f / zoom_factor).to_i
      src_x = (logo.width - src_size) / 2
      src_y = (logo.height - src_size) / 2
      
      # Create white circular background for logo
      logo_radius = (logo_size / 2).to_i
      draw_circular_background(png, center_x, center_y, logo_radius)
      Rails.logger.info "⚪ Circular background drawn, radius: #{logo_radius}"
      
      # Render logo as circular mask
      render_circular_logo(png, logo, center_x, center_y, logo_size, src_x, src_y, src_size)
      
      Rails.logger.info "✅ Logo added successfully"
      
    rescue => e
      Rails.logger.error "❌ Error loading logo: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end
  end

  # Draw circular white background for logo
  def draw_circular_background(png, center_x, center_y, radius)
    background_color = options[:background_color]
    
    (-radius..radius).each do |x|
      (-radius..radius).each do |y|
        distance = Math.sqrt(x * x + y * y)
        next if distance > radius
        
        plot_x = center_x + x
        plot_y = center_y + y
        
        next if plot_x < 0 || plot_x >= png.width || plot_y < 0 || plot_y >= png.height
        
        png[plot_x, plot_y] = background_color
      end
    end
  end

  # Render logo with circular mask
  def render_circular_logo(png, logo, center_x, center_y, target_size, src_x, src_y, src_size)
    radius = (target_size / 2).to_i
    
    (-radius..radius).each do |x|
      (-radius..radius).each do |y|
        distance = Math.sqrt(x * x + y * y)
        
        # Skip pixels outside circle
        next if distance > radius
        
        # Calculate anti-aliased alpha for smooth edges
        alpha = if distance < radius - 1
          1.0
        else
          1.0 - (distance - (radius - 1))
        end
        
        alpha = [[alpha, 0.0].max, 1.0].min
        next if alpha < 0.1
        
        # Calculate position on QR code
        plot_x = center_x + x
        plot_y = center_y + y
        
        next if plot_x < 0 || plot_x >= png.width || plot_y < 0 || plot_y >= png.height
        
        # Calculate position on source logo (with zoom)
        logo_x = src_x + ((x + radius) * src_size / target_size).to_i
        logo_y = src_y + ((y + radius) * src_size / target_size).to_i
        
        # Ensure logo coordinates are within bounds
        logo_x = [[logo_x, 0].max, logo.width - 1].min
        logo_y = [[logo_y, 0].max, logo.height - 1].min
        
        # Get logo pixel
        logo_pixel = logo[logo_x, logo_y]
        
        # Apply circular mask with anti-aliasing
        if alpha >= 0.99
          png[plot_x, plot_y] = logo_pixel
        else
          existing_color = png[plot_x, plot_y]
          blended_color = blend_colors_simple(existing_color, logo_pixel, alpha)
          png[plot_x, plot_y] = blended_color
        end
      end
    end
  end

  def default_options
    {
      module_size: 8,
      border_size: 20,
      corner_radius: 5,
      qr_size: 6,
      background_color: ChunkyPNG::Color::WHITE,
      foreground_color: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      data_type: :url,
      center_logo: true,
      logo_size: 60,              # Larger to accommodate circular crop
      logo_zoom: 1.3,             # Zoom in 30% on the logo
      gradient: true,
      gradient_start: ChunkyPNG::Color.rgb(124, 58, 237), # Purple (#7c3aed)
      gradient_end: ChunkyPNG::Color.rgb(59, 130, 246)    # Blue (#3b82f6)
    }
  end
end