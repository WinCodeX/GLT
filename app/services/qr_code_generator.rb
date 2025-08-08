# app/services/qr_code_generator.rb
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
    # Create comprehensive package data for QR code
    base_url = Rails.application.routes.url_helpers.root_url
    tracking_url = "#{base_url}track/#{package.code}"
    
    # You can customize what data goes into the QR code
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

  def create_styled_png(qrcode)
    # Calculate dimensions
    module_size = options[:module_size]
    border_size = options[:border_size]
    qr_modules = qrcode.modules.size
    
    total_size = (qr_modules * module_size) + (border_size * 2)
    
    # Create canvas
    png = ChunkyPNG::Image.new(total_size, total_size, options[:background_color])
    
    # Draw QR code with rounded corners
    qrcode.modules.each_with_index do |row, row_index|
      row.each_with_index do |module_dark, col_index|
        next unless module_dark
        
        x = border_size + (col_index * module_size)
        y = border_size + (row_index * module_size)
        
        # Determine corner rounding based on surrounding modules
        corner_radius = calculate_corner_radius(qrcode.modules, row_index, col_index)
        
        if corner_radius > 0
          draw_rounded_module(png, x, y, module_size, corner_radius)
        else
          draw_square_module(png, x, y, module_size)
        end
      end
    end
    
    # Add center logo if specified
    if options[:center_logo]
      add_center_logo(png, total_size)
    end
    
    # Add gradient effect if specified
    if options[:gradient]
      apply_gradient_effect(png)
    end
    
    png.to_blob
  end

  def calculate_corner_radius(modules, row, col)
    max_radius = options[:corner_radius]
    return 0 if max_radius == 0
    
    # Check surrounding modules to determine appropriate rounding
    # This creates the smooth, organic look like in your image
    
    # Get surrounding module states
    neighbors = {
      top: row > 0 ? modules[row - 1][col] : false,
      bottom: row < modules.size - 1 ? modules[row + 1][col] : false,
      left: col > 0 ? modules[row][col - 1] : false,
      right: col < modules[row].size - 1 ? modules[row][col + 1] : false,
      top_left: (row > 0 && col > 0) ? modules[row - 1][col - 1] : false,
      top_right: (row > 0 && col < modules[row].size - 1) ? modules[row - 1][col + 1] : false,
      bottom_left: (row < modules.size - 1 && col > 0) ? modules[row + 1][col - 1] : false,
      bottom_right: (row < modules.size - 1 && col < modules[row].size - 1) ? modules[row + 1][col + 1] : false
    }
    
    # Calculate rounding based on isolation (fewer neighbors = more rounding)
    connected_sides = [neighbors[:top], neighbors[:bottom], neighbors[:left], neighbors[:right]].count(true)
    
    case connected_sides
    when 0, 1 then max_radius # Isolated or end modules get full rounding
    when 2 then max_radius * 0.7 # Corner modules get medium rounding
    when 3 then max_radius * 0.4 # T-junction modules get slight rounding
    else 0 # Fully connected modules stay square
    end.to_i
  end

  def draw_rounded_module(png, x, y, size, radius)
    color = options[:foreground_color]
    
    # Draw the main rectangle
    png.rect(x + radius, y, x + size - radius - 1, y + size - 1, color, color)
    png.rect(x, y + radius, x + size - 1, y + size - radius - 1, color, color)
    
    # Draw rounded corners
    draw_rounded_corner(png, x + radius, y + radius, radius, :top_left, color)
    draw_rounded_corner(png, x + size - radius - 1, y + radius, radius, :top_right, color)
    draw_rounded_corner(png, x + radius, y + size - radius - 1, radius, :bottom_left, color)
    draw_rounded_corner(png, x + size - radius - 1, y + size - radius - 1, radius, :bottom_right, color)
  end

  def draw_rounded_corner(png, cx, cy, radius, corner, color)
    # Draw quarter circle for each corner
    (0..radius).each do |i|
      (0..radius).each do |j|
        distance = Math.sqrt(i * i + j * j)
        next if distance > radius
        
        case corner
        when :top_left
          png[cx - i, cy - j] = color if cx - i >= 0 && cy - j >= 0
        when :top_right
          png[cx + i, cy - j] = color if cy - j >= 0
        when :bottom_left
          png[cx - i, cy + j] = color if cx - i >= 0
        when :bottom_right
          png[cx + i, cy + j] = color
        end
      end
    end
  end

  def draw_square_module(png, x, y, size)
    png.rect(x, y, x + size - 1, y + size - 1, options[:foreground_color], options[:foreground_color])
  end

  def add_center_logo(png, total_size)
    # Add a center logo (like the paper plane in your image)
    center_x = total_size / 2
    center_y = total_size / 2
    logo_size = options[:logo_size]
    
    # Create circular background for logo
    radius = logo_size / 2
    logo_color = options[:logo_color]
    
    (-radius..radius).each do |x|
      (-radius..radius).each do |y|
        distance = Math.sqrt(x * x + y * y)
        next if distance > radius
        
        png[center_x + x, center_y + y] = logo_color
      end
    end
    
    # You can add actual logo image here using MiniMagick
    # For now, we'll just create a simple icon placeholder
    draw_simple_icon(png, center_x, center_y, logo_size)
  end

  def draw_simple_icon(png, center_x, center_y, size)
    # Draw a simple paper plane icon (simplified)
    icon_color = ChunkyPNG::Color::WHITE
    half_size = size / 4
    
    # Simple triangle representing paper plane
    (0..half_size).each do |i|
      png[center_x - half_size + i, center_y - i] = icon_color
      png[center_x - half_size + i, center_y + i] = icon_color
      png[center_x + i, center_y] = icon_color
    end
  end

  def apply_gradient_effect(png)
    # Apply gradient coloring similar to your image (purple to blue)
    width = png.width
    height = png.height
    
    png.width.times do |x|
      png.height.times do |y|
        current_pixel = png[x, y]
        next if current_pixel == options[:background_color]
        
        # Calculate position ratio (0.0 to 1.0)
        ratio = (x.to_f + y.to_f) / (width + height)
        
        # Interpolate between purple and blue
        new_color = interpolate_color(options[:gradient_start], options[:gradient_end], ratio)
        png[x, y] = new_color
      end
    end
  end

  def interpolate_color(color1, color2, ratio)
    r1, g1, b1 = [(color1 >> 24) & 0xff, (color1 >> 16) & 0xff, (color1 >> 8) & 0xff]
    r2, g2, b2 = [(color2 >> 24) & 0xff, (color2 >> 16) & 0xff, (color2 >> 8) & 0xff]
    
    r = (r1 + (r2 - r1) * ratio).to_i
    g = (g1 + (g2 - g1) * ratio).to_i
    b = (b1 + (b2 - b1) * ratio).to_i
    
    ChunkyPNG::Color.rgb(r, g, b)
  end

  def default_options
    {
      module_size: 12,
      border_size: 24,
      corner_radius: 4,
      qr_size: 4,
      background_color: ChunkyPNG::Color::WHITE,
      foreground_color: ChunkyPNG::Color.rgb(138, 43, 226), # Purple
      data_type: :url,
      center_logo: true,
      logo_size: 40,
      logo_color: ChunkyPNG::Color.rgb(138, 43, 226), # Purple
      gradient: true,
      gradient_start: ChunkyPNG::Color.rgb(138, 43, 226), # Purple
      gradient_end: ChunkyPNG::Color.rgb(30, 144, 255)    # Blue
    }
  end
end