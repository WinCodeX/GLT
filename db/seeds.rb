# db/seeds.rb
# Production-ready seed file with proper attribute names and error handling

puts "🌱 Starting to seed the database..."

# Wrap everything in a transaction for safety
ActiveRecord::Base.transaction do
  begin
    
    # === ROLES SETUP (CRITICAL FIRST STEP) ===
    puts "🔐 Setting up roles system..."
    
    # Define all required roles
    REQUIRED_ROLES = %w[client agent rider warehouse admin].freeze
    
    # Create roles with proper error handling
    REQUIRED_ROLES.each do |role_name|
      role = Role.find_or_create_by!(name: role_name)
      puts "  ✓ Role ready: #{role.name}"
    end
    
    puts "  📋 Total roles in system: #{Role.count}"
    
    # === USER CREATION HELPER ===
    def create_user_safely(email:, password:, first_name:, last_name:, phone_number:, role: nil)
      user = User.find_or_create_by!(email: email) do |u|
        u.password = password
        u.password_confirmation = password
        u.first_name = first_name
        u.last_name = last_name
        u.phone_number = phone_number  # Fixed: using phone_number not phone
      end
      
      # Add role with proper error handling
      if role && Role.find_by(name: role.to_s)
        unless user.has_role?(role)
          user.add_role(role)
          puts "  ✓ Added role '#{role}' to user: #{user.email}"
        else
          puts "  ✓ User already has role '#{role}': #{user.email}"
        end
      elsif role
        puts "  ⚠️  Warning: Role '#{role}' does not exist for user: #{user.email}"
      end
      
      puts "  ✓ User ready: #{user.email}#{role ? " (#{role})" : ""}"
      user
    rescue StandardError => e
      puts "  ❌ Error creating user #{email}: #{e.message}"
      puts "  📍 Error details: #{e.class} - #{e.backtrace.first}"
      raise e
    end
    
    # === USERS SETUP ===
    puts "👤 Creating system and main users..."
    
    # Create system user FIRST (required by agents)
    system_user = create_user_safely(
      email: "system@glt.co.ke",
      password: "SecureSystemPassword123!",
      first_name: "GLT",
      last_name: "System",
      phone_number: "+254700000000"  # Fixed: using phone_number
    )
    
    # Create main application users
    create_user_safely(
      email: "glenwinterg970@gmail.com",
      password: "Leviathan@Xcode",
      first_name: "Xs",
      last_name: "",
      phone_number: "+254712293377",  # Fixed: using phone_number
      role: :client
    )
    
    create_user_safely(
      email: "admin@example.com",
      password: "Password123",
      first_name: "Glen",
      last_name: "",
      phone_number: "+254712293377",  # Fixed: using phone_number
      role: :admin
    )
    
    # Development-only test user
    if Rails.env.development?
      create_user_safely(
        email: "test@example.com",
        password: "password123",
        first_name: "Test",
        last_name: "User",
        phone_number: "+254700000001"  # Fixed: using phone_number
      )
      puts "  📧 Dev Test User - Email: test@example.com, Password: password123"
    end
    


# === PACKAGE STATE FIX ===
puts "📦 Updating existing packages to 'pending' state..."

# Example: find by tracking codes NRB-001 and NRB-001-MCH
package_codes = ["NRB-001", "NRB-001-MCH"]

package_codes.each do |code|
  package = Package.find_by(code: code)
  if package
    package.update!(state: :pending) # if enum
    # package.update!(state: "pending") # if string
    puts "  ✓ Package #{code} updated to 'pending'"
  else
    puts "  ⚠️ Package #{code} not found, skipping..."
  end
end


    # === LOCATIONS SETUP ===
    puts "🗺️ Setting up locations with initials..."
    
    locations_data = [
      { name: "Nairobi", initials: "NRB" },
      { name: "Mombasa", initials: "MSA" },
      { name: "Kisumu", initials: "KSM" },
      { name: "Eldoret", initials: "ELD" },
      { name: "Nakuru", initials: "NKR" },
      { name: "Thika", initials: "THK" },
      { name: "Machakos", initials: "MCH" },
      { name: "Nyeri", initials: "NYR" },
      { name: "Meru", initials: "MRU" },
      { name: "Kisii", initials: "KSI" }
    ].freeze
    
    location_records = {}
    locations_data.each do |location_data|
      location = Location.find_or_create_by!(name: location_data[:name]) do |loc|
        loc.initials = location_data[:initials]
      end
      
      # Update initials if different
      if location.initials != location_data[:initials]
        location.update!(initials: location_data[:initials])
        puts "  ✓ Updated location: #{location.name} → #{location_data[:initials]}"
      else
        puts "  ✓ Location correct: #{location.name} (#{location.initials})"
      end
      
      location_records[location_data[:name]] = location
    end
    
    # === AREAS SETUP ===
    puts "🏢 Setting up areas within locations..."
    
    areas_data = [
      # Nairobi Areas
      { name: "CBD", initials: "CBD", location: "Nairobi" },
      { name: "Westlands", initials: "WTL", location: "Nairobi" },
      { name: "Karen", initials: "KRN", location: "Nairobi" },
      { name: "Kilimani", initials: "KLM", location: "Nairobi" },
      { name: "Kasarani", initials: "KSR", location: "Nairobi" },
      { name: "Embakasi", initials: "EMB", location: "Nairobi" },
      { name: "Kileleshwa", initials: "KLL", location: "Nairobi" },
      { name: "Lavington", initials: "LAV", location: "Nairobi" },
      { name: "Parklands", initials: "PKL", location: "Nairobi" },
      { name: "South B", initials: "STB", location: "Nairobi" },
      
      # Mombasa Areas
      { name: "Mombasa Island", initials: "MSI", location: "Mombasa" },
      { name: "Nyali", initials: "NYL", location: "Mombasa" },
      { name: "Bamburi", initials: "BMB", location: "Mombasa" },
      { name: "Likoni", initials: "LKN", location: "Mombasa" },
      { name: "Diani", initials: "DIA", location: "Mombasa" },
      { name: "Kilifi", initials: "KLF", location: "Mombasa" },
      
      # Kisumu Areas
      { name: "Kisumu Central", initials: "KSC", location: "Kisumu" },
      { name: "Kondele", initials: "KDL", location: "Kisumu" },
      { name: "Mamboleo", initials: "MBL", location: "Kisumu" },
      { name: "Milimani", initials: "MLM", location: "Kisumu" },
      { name: "Nyamasaria", initials: "NYM", location: "Kisumu" },
      
      # Eldoret Areas
      { name: "Eldoret Town", initials: "ETC", location: "Eldoret" },
      { name: "Langas", initials: "LNG", location: "Eldoret" },
      { name: "Pioneer", initials: "PNR", location: "Eldoret" },
      { name: "Kapsabet", initials: "KPS", location: "Eldoret" },
      { name: "Turbo", initials: "TRB", location: "Eldoret" },
      
      # Nakuru Areas
      { name: "Nakuru Town", initials: "NKT", location: "Nakuru" },
      { name: "Lanet", initials: "LNT", location: "Nakuru" },
      { name: "Bahati", initials: "BHT", location: "Nakuru" },
      { name: "Naivasha", initials: "NVS", location: "Nakuru" },
      { name: "Gilgil", initials: "GLG", location: "Nakuru" },
      
      # Other areas
      { name: "Thika Town", initials: "THT", location: "Thika" },
      { name: "Machakos Town", initials: "MCT", location: "Machakos" },
      { name: "Nyeri Town", initials: "NYT", location: "Nyeri" },
      { name: "Meru Town", initials: "MRT", location: "Meru" },
      { name: "Kisii Town", initials: "KST", location: "Kisii" }
    ].freeze
    
    area_records = {}
    areas_data.each do |area_data|
      location = location_records[area_data[:location]]
      unless location
        puts "  ❌ Error: Location '#{area_data[:location]}' not found for area '#{area_data[:name]}'"
        next
      end
      
      area = Area.find_or_create_by!(name: area_data[:name], location: location) do |a|
        a.initials = area_data[:initials]
      end
      
      # Update initials if different
      if area.initials != area_data[:initials]
        area.update!(initials: area_data[:initials])
        puts "  ✓ Updated area: #{area.name} → #{area.initials} in #{location.name}"
      end
      
      area_records[area_data[:name]] = area
    end
    
    # === AGENTS SETUP ===
    puts "👥 Creating agents..."
    
    agents_data = [
      { name: "GLT Express Hub", phone_number: "+254700100001", area: "CBD" },
      { name: "Westgate Courier Point", phone_number: "+254700100002", area: "Westlands" },
      { name: "Karen Shopping Centre Agent", phone_number: "+254700100003", area: "Karen" },
      { name: "Kilimani Plaza Pickup", phone_number: "+254700100004", area: "Kilimani" },
      { name: "Kasarani Express Station", phone_number: "+254700100005", area: "Kasarani" },
      { name: "Embakasi Delivery Hub", phone_number: "+254700100006", area: "Embakasi" },
      { name: "Island Express Centre", phone_number: "+254700200001", area: "Mombasa Island" },
      { name: "Nyali Cinemax Agent", phone_number: "+254700200002", area: "Nyali" },
      { name: "Bamburi Mtambo Pickup", phone_number: "+254700200003", area: "Bamburi" },
      { name: "Kisumu Central Agent", phone_number: "+254700300001", area: "Kisumu Central" },
      { name: "Eldoret Main Hub", phone_number: "+254700400001", area: "Eldoret Town" },
      { name: "Nakuru Town Centre", phone_number: "+254700500001", area: "Nakuru Town" },
      { name: "Thika Blue Post Agent", phone_number: "+254700600001", area: "Thika Town" },
      { name: "Machakos Town Agent", phone_number: "+254700700001", area: "Machakos Town" },
      { name: "Nyeri Central Agent", phone_number: "+254700800001", area: "Nyeri Town" },
      { name: "Meru Main Hub", phone_number: "+254700900001", area: "Meru Town" },
      { name: "Kisii Town Agent", phone_number: "+254701000001", area: "Kisii Town" }
    ].freeze
    
    agents_data.each do |agent_data|
      area = area_records[agent_data[:area]]
      unless area
        puts "  ⚠️  Warning: Area '#{agent_data[:area]}' not found for agent '#{agent_data[:name]}'"
        next
      end
      
      agent = Agent.find_or_create_by!(name: agent_data[:name]) do |a|
        a.phone = agent_data[:phone_number]  # Agent model uses 'phone' attribute
        a.area = area
        a.user = system_user
        a.active = true if a.respond_to?(:active)
      end
      puts "  ✓ Agent ready: #{agent.name} in #{area.name}, #{area.location.name}"
    end
    
    # === CATEGORIES SETUP ===
    puts "🏷️ Setting up business categories..."
    
    categories_data = [
      { name: "Books", description: "Books, literature, educational materials" },
      { name: "Clothes", description: "Clothing and fashion items" },
      { name: "Accessories", description: "Fashion and personal accessories" },
      { name: "Adult Content", description: "Adult-oriented products and materials" },
      { name: "African Inspired", description: "African-inspired products and crafts" },
      { name: "Agricultural equipment", description: "Farming and agricultural tools" },
      { name: "Apparel", description: "General clothing and apparel" },
      { name: "Arts and Design", description: "Art supplies and design materials" },
      { name: "Baby Products", description: "Baby care and children's products" },
      { name: "Bags", description: "Bags, luggage, and carrying cases" },
      { name: "Bakery, Pantry and Kitchen", description: "Baking supplies, pantry items, and kitchen equipment" },
      { name: "Beauty", description: "Beauty products and cosmetics" },
      { name: "Camping & Outdoor", description: "Camping and outdoor recreation equipment" },
      { name: "Car accessories", description: "Automotive accessories and parts" },
      { name: "Detergents and cleaning products", description: "Cleaning supplies and detergents" },
      { name: "Electronics", description: "Electronic devices and gadgets" },
      { name: "Furniture/upholstery", description: "Furniture and upholstery items" },
      { name: "Games", description: "Games, toys, and entertainment" },
      { name: "Gifts", description: "Gift items and novelties" },
      { name: "Home and Garden", description: "Home improvement and gardening supplies" },
      { name: "Jewellery", description: "Jewelry and precious accessories" },
      { name: "Medical equipments", description: "Medical devices and healthcare equipment" },
      { name: "Organic products", description: "Organic and natural products" },
      { name: "Perfume", description: "Perfumes and fragrances" },
      { name: "Phone accessories", description: "Mobile phone accessories and cases" },
      { name: "Plumbing and water supply", description: "Plumbing fixtures and water supply equipment" },
      { name: "Sports Wear and Improvement", description: "Sports equipment and athletic wear" },
      { name: "Stationery", description: "Office and school stationery supplies" },
      { name: "Utensils", description: "Kitchen utensils and cooking tools" },
      { name: "Other", description: "Miscellaneous products and services" }
    ].freeze
    
    categories_data.each do |category_data|
      category = Category.find_or_create_by!(name: category_data[:name]) do |c|
        c.description = category_data[:description]
        c.active = true
      end
      
      # Update description if different
      if category.description != category_data[:description]
        category.update!(description: category_data[:description])
        puts "  ✓ Updated category: #{category.name}"
      else
        puts "  ✓ Category ready: #{category.name}"
      end
    end
    
    puts "  📋 Total categories in system: #{Category.count}"
    
    # === PRICING SETUP ===
    puts "💰 Setting up pricing matrix..."
    
    # Helper method for calculating inter-city costs
    def calculate_inter_city_cost(origin, destination)
      major_routes = {
        ["Nairobi", "Mombasa"] => 420,
        ["Nairobi", "Kisumu"] => 400,
        ["Mombasa", "Kisumu"] => 390
      }
      
      route_key = [origin, destination].sort
      major_routes[route_key] || (origin == "Nairobi" || destination == "Nairobi" ? 380 : 370)
    end
    
    # Get all locations for pricing calculations
    all_locations = Location.all.to_a
    
    all_locations.each do |origin_location|
      all_locations.each do |destination_location|
        
        # Calculate base costs based on route type
        if origin_location == destination_location
          # Intra-city pricing
          base_doorstep_cost = 280
          base_mixed_cost = 230
        else
          # Inter-city pricing
          base_cost = calculate_inter_city_cost(origin_location.name, destination_location.name)
          base_doorstep_cost = base_cost + rand(-15..20)
          base_mixed_cost = ((base_doorstep_cost + 150) / 2).round
        end
        
        # Get areas for this location pair
        origin_areas = Area.where(location: origin_location)
        destination_areas = Area.where(location: destination_location)
        
        origin_areas.each do |origin_area|
          destination_areas.each do |destination_area|
            
            # Create doorstep delivery price
            Price.find_or_create_by!(
              origin_area: origin_area,
              destination_area: destination_area,
              delivery_type: 'doorstep'
            ) do |p|
              area_variation = rand(-8..8)
              p.cost = [[base_doorstep_cost + area_variation, 420].min, 250].max
            end
            
            # Create agent pickup price (standardized)
            Price.find_or_create_by!(
              origin_area: origin_area,
              destination_area: destination_area,
              delivery_type: 'agent'
            ) { |p| p.cost = 150 }
            
            # Create mixed delivery price
            Price.find_or_create_by!(
              origin_area: origin_area,
              destination_area: destination_area,
              delivery_type: 'mixed'
            ) do |p|
              area_variation = rand(-5..5)
              p.cost = [[base_mixed_cost + area_variation, 300].min, 200].max
            end
          end
        end
      end
    end
    
    # === COMPLETION SUMMARY ===
    puts "\n🎉 Database seeding completed successfully!"
    puts "📊 Final counts:"
    puts "  🔐 Roles: #{Role.count}"
    puts "  👤 Users: #{User.count}"
    puts "  🗺️ Locations: #{Location.count}"
    puts "  🏢 Areas: #{Area.count}"
    puts "  👥 Agents: #{Agent.count}"
    puts "  🏷️ Categories: #{Category.count}"
    puts "  💰 Prices: #{Price.count}"
    
    puts "\n🚀 System ready for package operations!"
    puts "\n💡 Test credentials:"
    puts "  📧 Admin: admin@example.com / Password123"
    puts "  📧 Client: glenwinterg970@gmail.com / Leviathan@Xcode"
    if Rails.env.development?
      puts "  📧 Test: test@example.com / password123"
    end
    
  rescue StandardError => e
    puts "\n❌ Seeding failed with error: #{e.message}"
    puts "📍 Error class: #{e.class}"
    puts "📍 Backtrace: #{e.backtrace.first(5).join("\n")}"
    raise e # Re-raise to trigger rollback
  end
end