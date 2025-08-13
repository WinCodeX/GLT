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
    create_organic_styled_png(qrcode)
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

  # COMPLETELY NEW: Organic flowing QR generation
  def create_organic_styled_png(qrcode)
    # High resolution for smooth organic shapes
    module_size = options[:module_size] * 3 # Triple resolution
    border_size = options[:border_size] * 3
    qr_modules = qrcode.modules.size
    
    total_size = (qr_modules * module_size) + (border_size * 2)
    
    Rails.logger.info "🌊 Creating organic QR: #{total_size}x#{total_size}, modules: #{qr_modules}"
    
    # Create high-resolution canvas
    png = ChunkyPNG::Image.new(total_size, total_size, options[:background_color])
    
    # Step 1: Analyze module connectivity and create clusters
    connected_clusters = analyze_connectivity(qrcode.modules)
    Rails.logger.info "🔗 Found #{connected_clusters.length} connected clusters"
    
    # Step 2: Generate organic shapes for each cluster
    connected_clusters.each_with_index do |cluster, index|
      Rails.logger.info "🎨 Rendering cluster #{index + 1} with #{cluster.length} modules"
      draw_organic_cluster(png, cluster, qr_modules, module_size, border_size)
    end
    
    # Step 3: Handle special patterns (finder patterns) with custom styling
    draw_enhanced_finder_patterns(png, qrcode.modules, module_size, border_size)
    
    # Step 4: Apply gradient effect across entire design
    if options[:gradient]
      apply_organic_gradient_effect(png)
    end
    
    # Step 5: Add refined center logo
    if options[:center_logo]
      add_organic_center_logo(png, total_size)
    end
    
    # Step 6: Scale down with anti-aliasing for final output
    final_size = total_size / 3
    scaled_png = scale_with_smoothing(png, final_size, final_size)
    
    Rails.logger.info "✅ Organic QR created successfully"
    scaled_png.to_blob
  end

  # NEW: Analyze module connectivity to create flowing clusters
  def analyze_connectivity(modules)
    visited = Array.new(modules.size) { Array.new(modules[0].size, false) }
    clusters = []
    
    modules.each_with_index do |row, row_index|
      row.each_with_index do |is_dark, col_index|
        next unless is_dark
        next if visited[row_index][col_index]
        next if is_finder_pattern_area?(row_index, col_index, modules.size)
        
        # Find connected component using flood fill
        cluster = flood_fill_cluster(modules, visited, row_index, col_index)
        clusters << cluster if cluster.length > 0
      end
    end
    
    clusters
  end

  # NEW: Flood fill to find connected modules
  def flood_fill_cluster(modules, visited, start_row, start_col)
    cluster = []
    queue = [[start_row, start_col]]
    
    while queue.any?
      row, col = queue.shift
      next if visited[row][col]
      next unless modules[row][col] # Must be dark module
      
      visited[row][col] = true
      cluster << [row, col]
      
      # Check 8-connected neighbors (including diagonals for organic flow)
      neighbors = [
        [row - 1, col - 1], [row - 1, col], [row - 1, col + 1],
        [row, col - 1],                     [row, col + 1],
        [row + 1, col - 1], [row + 1, col], [row + 1, col + 1]
      ]
      
      neighbors.each do |new_row, new_col|
        next if new_row < 0 || new_row >= modules.size
        next if new_col < 0 || new_col >= modules[new_row].size
        next if visited[new_row][new_col]
        next unless modules[new_row][new_col]
        next if is_finder_pattern_area?(new_row, new_col, modules.size)
        
        queue << [new_row, new_col]
      end
    end
    
    cluster
  end

  # NEW: Draw organic flowing shapes for connected clusters
  def draw_organic_cluster(png, cluster, qr_size, module_size, border_size)
    return if cluster.empty?
    
    # Create expanded cluster for organic flow
    expanded_cluster = expand_cluster_organically(cluster, qr_size)
    
    # Generate smooth contour for the expanded cluster
    contour_points = generate_smooth_contour(expanded_cluster, module_size, border_size)
    
    # Fill the organic shape
    fill_organic_shape(png, contour_points)
  end

  # NEW: Expand cluster to create organic connections
  def expand_cluster_organically(cluster, qr_size)
    expanded = Set.new(cluster)
    
    # Add connecting modules to create flow between nearby modules
    cluster.each do |row, col|
      # Look for nearby isolated modules to connect
      search_radius = 2
      
      (-search_radius..search_radius).each do |dr|
        (-search_radius..search_radius).each do |dc|
          new_row = row + dr
          new_col = col + dc
          
          next if new_row < 0 || new_row >= qr_size
          next if new_col < 0 || new_col >= qr_size
          
          # Calculate connection probability based on distance
          distance = Math.sqrt(dr * dr + dc * dc)
          connection_probability = [1.0 - (distance / search_radius), 0.0].max
          
          # Add organic connections
          if connection_probability > 0.3 && should_add_organic_connection?(cluster, new_row, new_col)
            expanded.add([new_row, new_col])
          end
        end
      end
    end
    
    expanded.to_a
  end

  # NEW: Determine if organic connection should be added
  def should_add_organic_connection?(cluster, row, col)
    # Count nearby cluster modules
    nearby_count = 0
    
    (-1..1).each do |dr|
      (-1..1).each do |dc|
        next if dr == 0 && dc == 0
        if cluster.include?([row + dr, col + dc])
          nearby_count += 1
        end
      end
    end
    
    # Add connection if it creates flow
    nearby_count >= 2
  end

  # NEW: Generate smooth contour around organic cluster
  def generate_smooth_contour(cluster, module_size, border_size)
    # Convert cluster to pixel coordinates
    pixel_points = cluster.map do |row, col|
      center_x = border_size + (col * module_size) + (module_size / 2)
      center_y = border_size + (row * module_size) + (module_size / 2)
      [center_x, center_y]
    end
    
    # Generate convex hull as base shape
    hull_points = convex_hull(pixel_points)
    
    # Smooth the hull with organic curves
    smooth_organic_contour(hull_points, module_size)
  end

  # NEW: Convex hull algorithm (Graham scan)
  def convex_hull(points)
    return points if points.length <= 3
    
    # Find bottom-most point (or left-most if tie)
    start = points.min_by { |p| [p[1], p[0]] }
    
    # Sort points by polar angle with respect to start point
    sorted = points.reject { |p| p == start }.sort_by do |p|
      angle = Math.atan2(p[1] - start[1], p[0] - start[0])
      [angle, distance_squared(start, p)]
    end
    
    # Build convex hull
    hull = [start]
    
    sorted.each do |point|
      # Remove points that create right turn
      while hull.length >= 2 && cross_product(hull[-2], hull[-1], point) <= 0
        hull.pop
      end
      hull << point
    end
    
    hull
  end

  def distance_squared(p1, p2)
    (p1[0] - p2[0])**2 + (p1[1] - p2[1])**2
  end

  def cross_product(o, a, b)
    (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
  end

  # NEW: Smooth organic contour with flowing curves
  def smooth_organic_contour(hull_points, module_size)
    return hull_points if hull_points.length < 3
    
    smoothed_points = []
    expansion_factor = module_size * 0.7 # How much to expand for organic flow
    
    hull_points.each_with_index do |point, i|
      prev_point = hull_points[(i - 1) % hull_points.length]
      next_point = hull_points[(i + 1) % hull_points.length]
      
      # Calculate smooth curve points using quadratic Bezier
      bezier_points = generate_bezier_curve(prev_point, point, next_point, expansion_factor)
      smoothed_points.concat(bezier_points)
    end
    
    smoothed_points
  end

  # NEW: Generate Bezier curve for smooth organic transitions
  def generate_bezier_curve(p0, p1, p2, expansion)
    curve_points = []
    steps = 8 # Number of curve segments
    
    # Calculate control point for organic curve
    # Offset the control point outward for expansion
    mid_x = (p0[0] + p2[0]) / 2.0
    mid_y = (p0[1] + p2[1]) / 2.0
    
    # Vector from midpoint to current point
    dx = p1[0] - mid_x
    dy = p1[1] - mid_y
    
    # Expand outward for organic flow
    length = Math.sqrt(dx * dx + dy * dy)
    if length > 0
      dx = dx / length * expansion
      dy = dy / length * expansion
    end
    
    control_point = [p1[0] + dx, p1[1] + dy]
    
    # Generate quadratic Bezier curve points
    steps.times do |i|
      t = i.to_f / (steps - 1)
      
      # Quadratic Bezier formula: B(t) = (1-t)²P0 + 2(1-t)tP1 + t²P2
      x = (1 - t)**2 * p0[0] + 2 * (1 - t) * t * control_point[0] + t**2 * p2[0]
      y = (1 - t)**2 * p0[1] + 2 * (1 - t) * t * control_point[1] + t**2 * p2[1]
      
      curve_points << [x.round, y.round]
    end
    
    curve_points
  end

  # NEW: Fill organic shapes with smooth edges
  def fill_organic_shape(png, contour_points)
    return if contour_points.empty?
    
    # Find bounding box
    min_x = contour_points.map { |p| p[0] }.min
    max_x = contour_points.map { |p| p[0] }.max
    min_y = contour_points.map { |p| p[1] }.min
    max_y = contour_points.map { |p| p[1] }.max
    
    # Fill interior points with anti-aliasing
    (min_x..max_x).each do |x|
      (min_y..max_y).each do |y|
        next if x < 0 || x >= png.width || y < 0 || y >= png.height
        
        if point_in_organic_shape?(x, y, contour_points)
          # Calculate distance to edge for anti-aliasing
          edge_distance = distance_to_contour(x, y, contour_points)
          alpha = calculate_organic_alpha(edge_distance)
          
          color = blend_colors_smooth(png[x, y], options[:foreground_color], alpha)
          png[x, y] = color
        end
      end
    end
  end

  # NEW: Enhanced point-in-polygon for organic shapes
  def point_in_organic_shape?(x, y, contour_points)
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

  # NEW: Calculate distance to contour for anti-aliasing
  def distance_to_contour(x, y, contour_points)
    min_distance = Float::INFINITY
    
    contour_points.each_with_index do |point, i|
      next_point = contour_points[(i + 1) % contour_points.length]
      
      # Distance to line segment
      dist = distance_to_line_segment([x, y], point, next_point)
      min_distance = [min_distance, dist].min
    end
    
    min_distance
  end

  def distance_to_line_segment(point, line_start, line_end)
    x, y = point
    x1, y1 = line_start
    x2, y2 = line_end
    
    # Calculate distance to line segment
    line_length_sq = (x2 - x1)**2 + (y2 - y1)**2
    return Math.sqrt((x - x1)**2 + (y - y1)**2) if line_length_sq == 0
    
    t = [0, [1, ((x - x1) * (x2 - x1) + (y - y1) * (y2 - y1)) / line_length_sq].min].max
    
    projection_x = x1 + t * (x2 - x1)
    projection_y = y1 + t * (y2 - y1)
    
    Math.sqrt((x - projection_x)**2 + (y - projection_y)**2)
  end

  # NEW: Organic alpha calculation for smooth edges
  def calculate_organic_alpha(edge_distance)
    smoothing_radius = 2.0
    
    if edge_distance <= smoothing_radius
      # Smooth falloff for organic edges
      1.0 - (edge_distance / smoothing_radius) * 0.3
    else
      0.0
    end
  end

  # NEW: Enhanced finder pattern drawing with organic style
  def draw_enhanced_finder_patterns(png, modules, module_size, border_size)
    finder_positions = [
      [0, 0],                           # Top-left
      [0, modules.size - 7],           # Top-right  
      [modules.size - 7, 0]            # Bottom-left
    ]
    
    finder_positions.each do |start_row, start_col|
      draw_organic_finder_pattern(png, start_row, start_col, module_size, border_size)
    end
  end

  # NEW: Organic finder pattern (rounded corner squares)
  def draw_organic_finder_pattern(png, start_row, start_col, module_size, border_size)
    # Calculate pixel position
    x = border_size + (start_col * module_size)
    y = border_size + (start_row * module_size)
    
    # Outer square (7x7) with organic rounding
    outer_size = 7 * module_size
    outer_radius = module_size * 2.5 # Large radius for organic look
    draw_organic_rounded_rect(png, x, y, outer_size, outer_size, outer_radius)
    
    # Inner white square (5x5)
    inner_x = x + module_size
    inner_y = y + module_size
    inner_size = 5 * module_size
    inner_radius = module_size * 1.8
    draw_organic_rounded_rect(png, inner_x, inner_y, inner_size, inner_size, inner_radius, options[:background_color])
    
    # Center dark square (3x3) with maximum organic rounding
    center_x = x + 2 * module_size
    center_y = y + 2 * module_size
    center_size = 3 * module_size
    center_radius = module_size * 1.2
    draw_organic_rounded_rect(png, center_x, center_y, center_size, center_size, center_radius)
  end

  # NEW: Draw organic rounded rectangles
  def draw_organic_rounded_rect(png, x, y, width, height, radius, color = nil)
    color ||= options[:foreground_color]
    
    # Clamp radius to prevent over-rounding
    max_radius = [width, height].min / 2
    radius = [radius, max_radius].min
    
    # Draw main rectangle body
    png.rect(x + radius, y, x + width - radius, y + height, color, color)
    png.rect(x, y + radius, x + width, y + height - radius, color, color)
    
    # Draw organic rounded corners with extra smoothness
    draw_organic_corner(png, x + radius, y + radius, radius, :top_left, color)
    draw_organic_corner(png, x + width - radius, y + radius, radius, :top_right, color)
    draw_organic_corner(png, x + radius, y + height - radius, radius, :bottom_left, color)
    draw_organic_corner(png, x + width - radius, y + height - radius, radius, :bottom_right, color)
  end

  # NEW: Organic corner rendering with smooth falloff
  def draw_organic_corner(png, cx, cy, radius, corner, color)
    # Enhanced corner with organic smoothing
    smoothing_factor = 1.3 # Makes corners more organic
    
    (-radius..radius).each do |i|
      (-radius..radius).each do |j|
        distance = Math.sqrt(i * i + j * j)
        next if distance > radius * smoothing_factor
        
        # Calculate alpha for smooth organic edges
        alpha = if distance <= radius
          1.0
        else
          # Smooth falloff for organic appearance
          1.0 - ((distance - radius) / (radius * (smoothing_factor - 1.0)))
        end
        
        alpha = [alpha, 0.0].max
        
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
        
        # Blend with existing pixel for smooth organic edges
        existing_color = png[plot_x, plot_y]
        blended_color = blend_colors_smooth(existing_color, color, alpha)
        png[plot_x, plot_y] = blended_color
      end
    end
  end

  # NEW: Smooth color blending for organic appearance
  def blend_colors_smooth(background, foreground, alpha)
    return background if alpha <= 0.0
    return foreground if alpha >= 1.0
    
    # Extract RGB components
    bg_r = (background >> 24) & 0xff
    bg_g = (background >> 16) & 0xff  
    bg_b = (background >> 8) & 0xff
    
    fg_r = (foreground >> 24) & 0xff
    fg_g = (foreground >> 16) & 0xff
    fg_b = (foreground >> 8) & 0xff
    
    # Smooth blending with gamma correction
    gamma = 2.2
    
    # Convert to gamma space
    bg_r_gamma = (bg_r / 255.0) ** gamma
    bg_g_gamma = (bg_g / 255.0) ** gamma
    bg_b_gamma = (bg_b / 255.0) ** gamma
    
    fg_r_gamma = (fg_r / 255.0) ** gamma
    fg_g_gamma = (fg_g / 255.0) ** gamma
    fg_b_gamma = (fg_b / 255.0) ** gamma
    
    # Blend in gamma space
    r_gamma = bg_r_gamma + (fg_r_gamma - bg_r_gamma) * alpha
    g_gamma = bg_g_gamma + (fg_g_gamma - bg_g_gamma) * alpha
    b_gamma = bg_b_gamma + (fg_b_gamma - bg_b_gamma) * alpha
    
    # Convert back to RGB
    r = ((r_gamma ** (1.0 / gamma)) * 255).round
    g = ((g_gamma ** (1.0 / gamma)) * 255).round
    b = ((b_gamma ** (1.0 / gamma)) * 255).round
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  # NEW: Apply organic gradient across flowing shapes
  def apply_organic_gradient_effect(png)
    width = png.width
    height = png.height
    
    # Create diagonal organic gradient
    width.times do |x|
      height.times do |y|
        current_pixel = png[x, y]
        next if current_pixel == options[:background_color]
        
        # Organic gradient calculation
        # Create flowing diagonal gradient like in reference image
        center_x = width / 2.0
        center_y = height / 2.0
        
        # Distance from center with organic curve
        distance_from_center = Math.sqrt((x - center_x)**2 + (y - center_y)**2)
        max_distance = Math.sqrt(center_x**2 + center_y**2)
        
        # Organic ratio calculation
        ratio = distance_from_center / max_distance
        
        # Apply organic curve to ratio for more natural gradient
        ratio = ratio ** 0.8 # Slight curve for organic feel
        ratio = [ratio, 1.0].min
        
        # Smooth color interpolation
        new_color = organic_color_interpolation(options[:gradient_start], options[:gradient_end], ratio)
        png[x, y] = new_color
      end
    end
  end

  # NEW: Organic color interpolation
  def organic_color_interpolation(color1, color2, ratio)
    # Apply organic curve to color transition
    curved_ratio = 1.0 - (1.0 - ratio)**1.5 # Organic easing curve
    
    # Extract components
    r1 = (color1 >> 24) & 0xff
    g1 = (color1 >> 16) & 0xff
    b1 = (color1 >> 8) & 0xff
    
    r2 = (color2 >> 24) & 0xff
    g2 = (color2 >> 16) & 0xff
    b2 = (color2 >> 8) & 0xff
    
    # Smooth interpolation
    r = (r1 + (r2 - r1) * curved_ratio).round
    g = (g1 + (g2 - g1) * curved_ratio).round
    b = (b1 + (b2 - b1) * curved_ratio).round
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  # NEW: Enhanced organic center logo
  def add_organic_center_logo(png, total_size)
    center_x = total_size / 2
    center_y = total_size / 2
    logo_size = options[:logo_size] * 3 # Larger for high-res
    
    # Create organic circular background with soft edges
    logo_radius = logo_size / 2
    
    # Draw organic circular background
    (-logo_radius..logo_radius).each do |x|
      (-logo_radius..logo_radius).each do |y|
        distance = Math.sqrt(x * x + y * y)
        
        if distance <= logo_radius * 1.2 # Slightly larger for organic feel
          # Organic alpha calculation
          alpha = if distance <= logo_radius * 0.8
            0.95 # Solid center
          else
            # Smooth organic falloff
            falloff = (distance - logo_radius * 0.8) / (logo_radius * 0.4)
            0.95 * (1.0 - falloff**1.5) # Organic curve
          end
          
          alpha = [alpha, 0.0].max
          
          if alpha > 0
            logo_color = ChunkyPNG::Color.rgba(124, 58, 237, (alpha * 255).round)
            existing_color = png[center_x + x, center_y + y]
            blended_color = blend_colors_smooth(existing_color, logo_color, alpha)
            png[center_x + x, center_y + y] = blended_color
          end
        end
      end
    end
    
    # Draw refined organic paper plane
    draw_organic_paper_plane(png, center_x, center_y, logo_size)
  end

  # NEW: Organic paper plane with flowing lines
  def draw_organic_paper_plane(png, center_x, center_y, size)
    icon_color = ChunkyPNG::Color::WHITE
    icon_size = size * 0.35
    
    # Organic paper plane shape with flowing curves
    main_points = [
      [center_x - icon_size * 0.4, center_y - icon_size * 0.5],
      [center_x + icon_size * 0.5, center_y],
      [center_x - icon_size * 0.4, center_y + icon_size * 0.5],
      [center_x - icon_size * 0.15, center_y]
    ]
    
    # Draw organic shape with anti-aliasing
    fill_organic_shape_simple(png, main_points, icon_color)
    
    # Add flowing wing detail
    wing_points = [
      [center_x - icon_size * 0.15, center_y - icon_size * 0.25],
      [center_x + icon_size * 0.15, center_y - icon_size * 0.35],
      [center_x + icon_size * 0.25, center_y - icon_size * 0.1],
      [center_x, center_y]
    ]
    
    fill_organic_shape_simple(png, wing_points, icon_color)
  end

  # NEW: Simple organic shape filling
  def fill_organic_shape_simple(png, points, color)
    return if points.length < 3
    
    min_x = points.map { |p| p[0] }.min.round
    max_x = points.map { |p| p[0] }.max.round
    min_y = points.map { |p| p[1] }.min.round
    max_y = points.map { |p| p[1] }.max.round
    
    (min_x..max_x).each do |x|
      (min_y..max_y).each do |y|
        next if x < 0 || x >= png.width || y < 0 || y >= png.height
        
        if point_in_organic_shape?(x, y, points.map { |p| [p[0].round, p[1].round] })
          png[x, y] = color
        end
      end
    end
  end

  # NEW: Check if position is in finder pattern area
  def is_finder_pattern_area?(row, col, qr_size)
    finder_size = 7
    
    # Top-left finder
    return true if row < finder_size && col < finder_size
    
    # Top-right finder  
    return true if row < finder_size && col >= qr_size - finder_size
    
    # Bottom-left finder
    return true if row >= qr_size - finder_size && col < finder_size
    
    false
  end

  # NEW: Enhanced scaling with organic smoothing
  def scale_with_smoothing(png, target_width, target_height)
    scaled = ChunkyPNG::Image.new(target_width, target_height, options[:background_color])
    
    x_ratio = png.width.to_f / target_width
    y_ratio = png.height.to_f / target_height
    
    # Bilinear interpolation for smooth scaling
    target_width.times do |x|
      target_height.times do |y|
        # Sample multiple points for smoothing
        orig_x = x * x_ratio
        orig_y = y * y_ratio
        
        # Bilinear interpolation
        x1 = orig_x.floor
        y1 = orig_y.floor
        x2 = [x1 + 1, png.width - 1].min
        y2 = [y1 + 1, png.height - 1].min
        
        # Get the four surrounding pixels
        c1 = png[x1, y1]
        c2 = png[x2, y1]
        c3 = png[x1, y2]
        c4 = png[x2, y2]
        
        # Interpolate
        fx = orig_x - x1
        fy = orig_y - y1
        
        # Bilinear interpolation
        top = interpolate_colors_linear(c1, c2, fx)
        bottom = interpolate_colors_linear(c3, c4, fx)
        final_color = interpolate_colors_linear(top, bottom, fy)
        
        scaled[x, y] = final_color
      end
    end
    
    scaled
  end

  # NEW: Linear color interpolation helper
  def interpolate_colors_linear(color1, color2, ratio)
    r1 = (color1 >> 24) & 0xff
    g1 = (color1 >> 16) & 0xff
    b1 = (color1 >> 8) & 0xff
    
    r2 = (color2 >> 24) & 0xff
    g2 = (color2 >> 16) & 0xff
    b2 = (color2 >> 8) & 0xff
    
    r = (r1 + (r2 - r1) * ratio).round
    g = (g1 + (g2 - g1) * ratio).round
    b = (b1 + (b2 - b1) * ratio).round
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  def default_options
    {
      module_size: 8,              # Base module size
      border_size: 24,             # Border for clean appearance
      corner_radius: 6,            # Enhanced rounding for organic look
      qr_size: 6,                  # QR complexity level
      background_color: ChunkyPNG::Color::WHITE,
      foreground_color: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      data_type: :url,
      center_logo: true,
      logo_size: 32,               # Larger logo for prominence
      logo_color: ChunkyPNG::Color.rgb(124, 58, 237), # Purple
      gradient: true,              # Enable organic gradient
      gradient_start: ChunkyPNG::Color.rgb(124, 58, 237), # Purple (#7c3aed)
      gradient_end: ChunkyPNG::Color.rgb(59, 130, 246)    # Blue (#3b82f6)
    }
  end
end