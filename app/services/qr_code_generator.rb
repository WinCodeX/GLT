# =====================================================
# ENHANCED: app/services/qr_code_generator.rb - Organic Flowing QR Codes
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
    
    # Create organic flowing styled PNG
    create_organic_flowing_png(qrcode)
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

  # COMPLETELY REWRITTEN: Organic flowing QR generation
  def create_organic_flowing_png(qrcode)
    # Higher resolution for smooth organic shapes
    module_size = options[:module_size] * 4 # 4x resolution for ultra-smooth
    border_size = options[:border_size] * 4
    qr_modules = qrcode.modules.size
    
    total_size = (qr_modules * module_size) + (border_size * 2)
    
    Rails.logger.info "🌊 Creating organic flowing QR: #{total_size}x#{total_size}"
    
    # Create high-resolution canvas
    png = ChunkyPNG::Image.new(total_size, total_size, options[:background_color])
    
    # Step 1: Find connected components for flowing shapes
    connected_clusters = find_flowing_clusters(qrcode.modules)
    
    # Step 2: Draw organic shapes for each cluster
    connected_clusters.each do |cluster|
      next if cluster.empty?
      draw_flowing_organic_shape(png, cluster, module_size, border_size)
    end
    
    # Step 3: Draw enhanced organic finder patterns
    draw_organic_finder_patterns(png, qrcode.modules, module_size, border_size)
    
    # Step 4: Apply smooth gradient
    if options[:gradient]
      apply_flowing_gradient(png)
    end
    
    # Step 5: Add organic center logo
    if options[:center_logo]
      add_flowing_center_logo(png, total_size)
    end
    
    # Step 6: Scale down with premium anti-aliasing
    final_size = total_size / 4
    scaled_png = premium_scale_down(png, final_size, final_size)
    
    Rails.logger.info "✅ Organic flowing QR created successfully"
    scaled_png.to_blob
  end

  # NEW: Find clusters of connected modules for flowing shapes
  def find_flowing_clusters(modules)
    visited = Array.new(modules.size) { Array.new(modules[0].size, false) }
    clusters = []
    
    modules.each_with_index do |row, row_index|
      row.each_with_index do |is_dark, col_index|
        next unless is_dark
        next if visited[row_index][col_index]
        next if is_finder_area?(row_index, col_index, modules.size)
        
        # Find connected component
        cluster = flood_fill_organic(modules, visited, row_index, col_index)
        clusters << cluster if cluster.length > 0
      end
    end
    
    clusters
  end

  # NEW: Organic flood fill with diagonal connections
  def flood_fill_organic(modules, visited, start_row, start_col)
    cluster = []
    queue = [[start_row, start_col]]
    
    while queue.any?
      row, col = queue.shift
      next if visited[row][col]
      next unless modules[row][col]
      
      visited[row][col] = true
      cluster << [row, col]
      
      # 8-connected neighbors for flowing organic shapes
      [
        [row-1, col-1], [row-1, col], [row-1, col+1],
        [row, col-1],                 [row, col+1],
        [row+1, col-1], [row+1, col], [row+1, col+1]
      ].each do |new_row, new_col|
        next if new_row < 0 || new_row >= modules.size
        next if new_col < 0 || new_col >= modules[new_row].size
        next if visited[new_row][new_col]
        next unless modules[new_row][new_col]
        next if is_finder_area?(new_row, new_col, modules.size)
        
        queue << [new_row, new_col]
      end
    end
    
    cluster
  end

  # NEW: Draw flowing organic shapes for clusters
  def draw_flowing_organic_shape(png, cluster, module_size, border_size)
    # Expand cluster for organic flow
    expanded_points = []
    
    cluster.each do |row, col|
      center_x = border_size + (col * module_size) + (module_size / 2)
      center_y = border_size + (row * module_size) + (module_size / 2)
      
      # Add multiple points around each module for organic shape
      radius = module_size * 0.6
      
      8.times do |i|
        angle = (i * Math::PI * 2) / 8
        px = center_x + Math.cos(angle) * radius
        py = center_y + Math.sin(angle) * radius
        expanded_points << [px, py]
      end
    end
    
    # Create flowing hull around all points
    hull_points = convex_hull_organic(expanded_points)
    
    # Smooth the hull into organic flowing curves
    smoothed_contour = create_flowing_contour(hull_points, module_size)
    
    # Fill the organic shape
    fill_flowing_shape(png, smoothed_contour)
  end

  # NEW: Organic convex hull
  def convex_hull_organic(points)
    return points if points.length <= 3
    
    # Find bottom-left point
    start = points.min_by { |p| [p[1], p[0]] }
    
    # Sort by polar angle
    sorted = points.reject { |p| p == start }.sort_by do |p|
      angle = Math.atan2(p[1] - start[1], p[0] - start[0])
      [angle, (p[0] - start[0])**2 + (p[1] - start[1])**2]
    end
    
    # Build hull
    hull = [start]
    
    sorted.each do |point|
      while hull.length >= 2 && cross_product_organic(hull[-2], hull[-1], point) <= 0
        hull.pop
      end
      hull << point
    end
    
    hull
  end

  def cross_product_organic(o, a, b)
    (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
  end

  # NEW: Create flowing contour with organic curves
  def create_flowing_contour(hull_points, module_size)
    return hull_points if hull_points.length < 3
    
    flowing_points = []
    expansion = module_size * 0.4 # Organic expansion factor
    
    hull_points.each_with_index do |point, i|
      prev_point = hull_points[(i - 1) % hull_points.length]
      next_point = hull_points[(i + 1) % hull_points.length]
      
      # Generate flowing curve between points
      curve_segments = generate_organic_curve(prev_point, point, next_point, expansion)
      flowing_points.concat(curve_segments)
    end
    
    flowing_points
  end

  # NEW: Generate organic curves between points
  def generate_organic_curve(p0, p1, p2, expansion)
    curve_points = []
    segments = 12 # More segments for smoother curves
    
    # Calculate organic control points
    mid_x = (p0[0] + p2[0]) / 2.0
    mid_y = (p0[1] + p2[1]) / 2.0
    
    # Vector from midpoint to current point (for expansion)
    dx = p1[0] - mid_x
    dy = p1[1] - mid_y
    
    # Normalize and expand for organic flow
    length = Math.sqrt(dx * dx + dy * dy)
    if length > 0
      dx = (dx / length) * expansion
      dy = (dy / length) * expansion
    end
    
    control_point = [p1[0] + dx, p1[1] + dy]
    
    # Generate smooth quadratic Bezier curve
    segments.times do |i|
      t = i.to_f / (segments - 1)
      
      # Quadratic Bezier with organic easing
      organic_t = t * t * (3.0 - 2.0 * t) # Smooth step function
      
      x = (1 - organic_t)**2 * p0[0] + 2 * (1 - organic_t) * organic_t * control_point[0] + organic_t**2 * p2[0]
      y = (1 - organic_t)**2 * p0[1] + 2 * (1 - organic_t) * organic_t * control_point[1] + organic_t**2 * p2[1]
      
      curve_points << [x.round, y.round]
    end
    
    curve_points
  end

  # NEW: Fill flowing organic shapes
  def fill_flowing_shape(png, contour_points)
    return if contour_points.empty?
    
    # Find bounding box
    min_x = contour_points.map { |p| p[0] }.min
    max_x = contour_points.map { |p| p[0] }.max
    min_y = contour_points.map { |p| p[1] }.min
    max_y = contour_points.map { |p| p[1] }.max
    
    # Fill with anti-aliasing for smooth edges
    (min_x..max_x).each do |x|
      (min_y..max_y).each do |y|
        next if x < 0 || x >= png.width || y < 0 || y >= png.height
        
        if point_inside_flowing_shape?(x, y, contour_points)
          # Calculate edge distance for smooth anti-aliasing
          edge_dist = distance_to_flowing_edge(x, y, contour_points)
          alpha = calculate_flowing_alpha(edge_dist)
          
          existing_color = png[x, y]
          blended_color = blend_organic_colors(existing_color, options[:foreground_color], alpha)
          png[x, y] = blended_color
        end
      end
    end
  end

  # NEW: Point-in-polygon test for flowing shapes
  def point_inside_flowing_shape?(x, y, contour_points)
    return false if contour_points.length < 3
    
    inside = false
    j = contour_points.length - 1
    
    contour_points.each_with_index do |point, i|
      xi, yi = point
      xj, yj = contour_points[j]
      
      if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
        inside = !inside
      end
      
      j = i
    end
    
    inside
  end

  # NEW: Distance to flowing edge calculation
  def distance_to_flowing_edge(x, y, contour_points)
    min_distance = Float::INFINITY
    
    contour_points.each_with_index do |point, i|
      next_point = contour_points[(i + 1) % contour_points.length]
      
      dist = distance_to_line_segment([x, y], point, next_point)
      min_distance = [min_distance, dist].min
    end
    
    min_distance
  end

  def distance_to_line_segment(point, line_start, line_end)
    x, y = point
    x1, y1 = line_start
    x2, y2 = line_end
    
    line_length_sq = (x2 - x1)**2 + (y2 - y1)**2
    return Math.sqrt((x - x1)**2 + (y - y1)**2) if line_length_sq == 0
    
    t = [0, [1, ((x - x1) * (x2 - x1) + (y - y1) * (y2 - y1)) / line_length_sq].min].max
    
    projection_x = x1 + t * (x2 - x1)
    projection_y = y1 + t * (y2 - y1)
    
    Math.sqrt((x - projection_x)**2 + (y - projection_y)**2)
  end

  # NEW: Flowing alpha calculation for organic edges
  def calculate_flowing_alpha(edge_distance)
    smoothing_radius = 3.0
    
    if edge_distance <= smoothing_radius
      # Organic smooth falloff
      base_alpha = 1.0 - (edge_distance / smoothing_radius)
      base_alpha ** 0.6 # Organic curve
    else
      0.0
    end
  end

  # NEW: Draw organic finder patterns (corner squares)
  def draw_organic_finder_patterns(png, modules, module_size, border_size)
    finder_positions = [
      [0, 0],                           # Top-left
      [0, modules.size - 7],           # Top-right  
      [modules.size - 7, 0]            # Bottom-left
    ]
    
    finder_positions.each do |start_row, start_col|
      draw_single_organic_finder(png, start_row, start_col, module_size, border_size)
    end
  end

  # NEW: Single organic finder pattern with flowing rounded rectangles
  def draw_single_organic_finder(png, start_row, start_col, module_size, border_size)
    x = border_size + (start_col * module_size)
    y = border_size + (start_row * module_size)
    
    # Outer flowing rectangle (7x7)
    outer_size = 7 * module_size
    outer_radius = module_size * 3.0 # Very large radius for organic flow
    draw_super_rounded_rect(png, x, y, outer_size, outer_size, outer_radius, options[:foreground_color])
    
    # Inner white space (5x5) 
    inner_x = x + module_size
    inner_y = y + module_size
    inner_size = 5 * module_size
    inner_radius = module_size * 2.2
    draw_super_rounded_rect(png, inner_x, inner_y, inner_size, inner_size, inner_radius, options[:background_color])
    
    # Center flowing square (3x3) - almost circular
    center_x = x + 2 * module_size
    center_y = y + 2 * module_size
    center_size = 3 * module_size
    center_radius = module_size * 1.4 # Almost circular
    draw_super_rounded_rect(png, center_x, center_y, center_size, center_size, center_radius, options[:foreground_color])
  end

  # NEW: Super rounded rectangles for organic appearance
  def draw_super_rounded_rect(png, x, y, width, height, radius, color)
    # Clamp radius
    max_radius = [width, height].min / 2.0
    radius = [radius, max_radius].min
    
    # Draw main body (avoiding corners)
    png.rect(x + radius, y, x + width - radius, y + height, color, color)
    png.rect(x, y + radius, x + width, y + height - radius, color, color)
    
    # Draw organic rounded corners
    corners = [
      [x + radius, y + radius, :top_left],
      [x + width - radius, y + radius, :top_right],
      [x + radius, y + height - radius, :bottom_left],
      [x + width - radius, y + height - radius, :bottom_right]
    ]
    
    corners.each do |cx, cy, corner_type|
      draw_organic_flowing_corner(png, cx, cy, radius, color)
    end
  end

  # NEW: Organic flowing corners with smooth anti-aliasing
  def draw_organic_flowing_corner(png, cx, cy, radius, color)
    organic_radius = radius * 1.1 # Slightly larger for organic flow
    
    (-organic_radius..organic_radius).each do |i|
      (-organic_radius..organic_radius).each do |j|
        distance = Math.sqrt(i * i + j * j)
        
        if distance <= organic_radius
          # Calculate organic alpha with smooth falloff
          alpha = if distance <= radius * 0.9
            1.0
          else
            # Smooth organic falloff
            falloff_distance = distance - radius * 0.9
            max_falloff = organic_radius - radius * 0.9
            1.0 - (falloff_distance / max_falloff) ** 1.5 # Organic curve
          end
          
          alpha = [alpha, 0.0].max
          
          plot_x = (cx + i).round
          plot_y = (cy + j).round
          
          next if plot_x < 0 || plot_x >= png.width || plot_y < 0 || plot_y >= png.height
          
          if alpha > 0.05 # Threshold for visible pixels
            existing_color = png[plot_x, plot_y]
            blended_color = blend_organic_colors(existing_color, color, alpha)
            png[plot_x, plot_y] = blended_color
          end
        end
      end
    end
  end

  # NEW: Organic color blending with gamma correction
  def blend_organic_colors(background, foreground, alpha)
    return background if alpha <= 0.0
    return foreground if alpha >= 1.0
    
    # Extract RGB components
    bg_r = (background >> 24) & 0xff
    bg_g = (background >> 16) & 0xff  
    bg_b = (background >> 8) & 0xff
    
    fg_r = (foreground >> 24) & 0xff
    fg_g = (foreground >> 16) & 0xff
    fg_b = (foreground >> 8) & 0xff
    
    # Gamma-corrected blending for organic smoothness
    gamma = 2.2
    
    bg_r_lin = (bg_r / 255.0) ** gamma
    bg_g_lin = (bg_g / 255.0) ** gamma
    bg_b_lin = (bg_b / 255.0) ** gamma
    
    fg_r_lin = (fg_r / 255.0) ** gamma
    fg_g_lin = (fg_g / 255.0) ** gamma
    fg_b_lin = (fg_b / 255.0) ** gamma
    
    # Blend in linear space
    r_lin = bg_r_lin + (fg_r_lin - bg_r_lin) * alpha
    g_lin = bg_g_lin + (fg_g_lin - bg_g_lin) * alpha
    b_lin = bg_b_lin + (fg_b_lin - bg_b_lin) * alpha
    
    # Convert back to sRGB
    r = ((r_lin ** (1.0 / gamma)) * 255).round
    g = ((g_lin ** (1.0 / gamma)) * 255).round
    b = ((b_lin ** (1.0 / gamma)) * 255).round
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  # NEW: Apply flowing gradient across organic shapes
  def apply_flowing_gradient(png)
    width = png.width
    height = png.height
    diagonal_length = Math.sqrt(width * width + height * height)
    
    width.times do |x|
      height.times do |y|
        current_pixel = png[x, y]
        next if current_pixel == options[:background_color]
        
        # Calculate organic gradient position
        # Diagonal gradient with organic curve
        distance_from_corner = Math.sqrt((x**2) + (y**2))
        ratio = distance_from_corner / diagonal_length
        
        # Apply organic easing curve
        organic_ratio = ratio ** 0.7 # Gentle organic curve
        organic_ratio = [organic_ratio, 1.0].min
        
        # Interpolate colors with organic transition
        new_color = interpolate_organic_colors(options[:gradient_start], options[:gradient_end], organic_ratio)
        png[x, y] = new_color
      end
    end
  end

  # NEW: Organic color interpolation
  def interpolate_organic_colors(color1, color2, ratio)
    # Apply organic transition curve
    curved_ratio = ratio * ratio * (3.0 - 2.0 * ratio) # Smoothstep for organic feel
    
    r1 = (color1 >> 24) & 0xff
    g1 = (color1 >> 16) & 0xff
    b1 = (color1 >> 8) & 0xff
    
    r2 = (color2 >> 24) & 0xff
    g2 = (color2 >> 16) & 0xff
    b2 = (color2 >> 8) & 0xff
    
    r = (r1 + (r2 - r1) * curved_ratio).round
    g = (g1 + (g2 - g1) * curved_ratio).round
    b = (b1 + (b2 - b1) * curved_ratio).round
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  # NEW: Flowing center logo with organic design
  def add_flowing_center_logo(png, total_size)
    center_x = total_size / 2
    center_y = total_size / 2
    logo_size = options[:logo_size] * 4 # Larger for high-res
    
    # Create organic flowing circular background
    logo_radius = logo_size / 2
    
    (-logo_radius..logo_radius).each do |x|
      (-logo_radius..logo_radius).each do |y|
        distance = Math.sqrt(x * x + y * y)
        organic_radius = logo_radius * 1.1 # Slightly larger for organic flow
        
        if distance <= organic_radius
          # Organic alpha with smooth falloff
          alpha = if distance <= logo_radius * 0.85
            0.98
          else
            falloff = (distance - logo_radius * 0.85) / (organic_radius - logo_radius * 0.85)
            0.98 * (1.0 - falloff ** 1.8) # Organic falloff curve
          end
          
          alpha = [alpha, 0.0].max
          
          if alpha > 0.05
            plot_x = center_x + x
            plot_y = center_y + y
            
            next if plot_x < 0 || plot_x >= png.width || plot_y < 0 || plot_y >= png.height
            
            logo_color = ChunkyPNG::Color.rgba(124, 58, 237, (alpha * 255).round)
            existing_color = png[plot_x, plot_y]
            blended_color = blend_organic_colors(existing_color, logo_color, alpha)
            png[plot_x, plot_y] = blended_color
          end
        end
      end
    end
    
    # Draw flowing paper plane icon
    draw_flowing_paper_plane(png, center_x, center_y, logo_size)
  end

  # NEW: Flowing paper plane with organic curves
  def draw_flowing_paper_plane(png, center_x, center_y, size)
    icon_color = ChunkyPNG::Color::WHITE
    icon_size = size * 0.35
    
    # Organic paper plane with flowing lines
    plane_points = []
    
    # Main body with organic curve
    12.times do |i|
      angle = (i * Math::PI * 2) / 12
      
      # Create organic paper plane shape
      if i < 4 # Front section
        radius = icon_size * 0.5
        px = center_x + Math.cos(angle + Math::PI) * radius * 0.8
        py = center_y + Math.sin(angle + Math::PI) * radius * 0.6
      else # Wing sections  
        radius = icon_size * 0.3
        px = center_x + Math.cos(angle) * radius
        py = center_y + Math.sin(angle) * radius * 0.4
      end
      
      plane_points << [px.round, py.round]
    end
    
    # Fill organic paper plane shape
    fill_flowing_shape(png, plane_points)
  end

  # NEW: Premium scaling with advanced anti-aliasing
  def premium_scale_down(png, target_width, target_height)
    scaled = ChunkyPNG::Image.new(target_width, target_height, options[:background_color])
    
    x_ratio = png.width.to_f / target_width
    y_ratio = png.height.to_f / target_height
    
    # Super-sampling for premium quality
    target_width.times do |x|
      target_height.times do |y|
        # Sample 4 points for better quality
        colors = []
        
        [
          [x * x_ratio, y * y_ratio],
          [(x + 0.5) * x_ratio, y * y_ratio],
          [x * x_ratio, (y + 0.5) * y_ratio],
          [(x + 0.5) * x_ratio, (y + 0.5) * y_ratio]
        ].each do |sample_x, sample_y|
          sx = sample_x.round.clamp(0, png.width - 1)
          sy = sample_y.round.clamp(0, png.height - 1)
          colors << png[sx, sy]
        end
        
        # Average the sampled colors for anti-aliasing
        avg_color = average_colors(colors)
        scaled[x, y] = avg_color
      end
    end
    
    scaled
  end

  # NEW: Average multiple colors for anti-aliasing
  def average_colors(colors)
    return colors.first if colors.length == 1
    
    total_r = total_g = total_b = 0
    
    colors.each do |color|
      total_r += (color >> 24) & 0xff
      total_g += (color >> 16) & 0xff
      total_b += (color >> 8) & 0xff
    end
    
    count = colors.length
    avg_r = (total_r / count).round
    avg_g = (total_g / count).round
    avg_b = (total_b / count).round
    
    ChunkyPNG::Color.rgb(avg_r, avg_g, avg_b)
  end

  # Helper: Check if position is in finder pattern area
  def is_finder_area?(row, col, qr_size)
    finder_size = 7
    
    # Top-left finder
    return true if row < finder_size && col < finder_size
    
    # Top-right finder  
    return true if row < finder_size && col >= qr_size - finder_size
    
    # Bottom-left finder
    return true if row >= qr_size - finder_size && col < finder_size
    
    false
  end

  def default_options
    {
      module_size: 6,              # Smaller base size for more detail
      border_size: 18,             # Proportional border
      corner_radius: 4,            # Enhanced rounding
      qr_size: 6,                  # QR complexity level
      background_color: ChunkyPNG::Color::WHITE,
      foreground_color: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      data_type: :url,
      center_logo: true,
      logo_size: 24,               # Proportional logo size
      logo_color: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      gradient: true,              # Enable flowing gradient
      gradient_start: ChunkyPNG::Color.rgb(124, 58, 237), # Purple (#7c3aed)
      gradient_end: ChunkyPNG::Color.rgb(59, 130, 246)    # Blue (#3b82f6)
    }
  end
end