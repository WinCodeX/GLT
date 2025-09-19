# db/seeds.rb - UPDATED: Enhanced seed file with comprehensive pricing for all delivery types

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

create_user_safely(
      email: "glen@glt.co.ke",
      password: "Leviathan@Xcode",
      first_name: "Glen",
      last_name: "",
      phone_number: "+254712293377",  # Fixed: using phone_number
      role: :admin
    )

create_user_safely(
      email: "lisa@glt.com",
      password: "Tumaforlife96",
      first_name: "Wambui",
      last_name: "Nganga",
      phone_number: "+254729688583",  # Fixed: using phone_number
      role: :admin
    )

    create_user_safely(
      email: "lisa@glt.co.ke",
      password: "Tumaforlife96",
      first_name: "Wambui",
      last_name: "Nganga",
      phone_number: "+254729688583",  # Fixed: using phone_number
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
      { name: "Bible", description: "Bibles, religious texts, and Christian literature" },
      { name: "Clothes", description: "Clothing and fashion items" },
      { name: "Accessories", description: "Fashion and personal accessories" },
      { name: "Rosaries", description: "Religious rosaries, prayer beads, and devotional items" },
      { name: "African Inspired", description: "African-inspired products and crafts" },
      { name: "Agricultural equipment", description: "Farming and agricultural tools" },
      { name: "Anime merch", description: "Anime merchandise, collectibles, and related products" },
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
    
    # === ENHANCED PRICING SETUP ===
    puts "💰 Setting up comprehensive pricing matrix for all delivery types..."
    
    # Clear existing prices to avoid conflicts
    Price.delete_all
    puts "  🗑️ Cleared existing pricing data"
    
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

    # Package size multipliers
    def get_package_size_multiplier(size)
      case size
      when 'small' then 0.8
      when 'large' then 1.4
      else 1.0 # medium
      end
    end

    # Calculate delivery type pricing
    def calculate_delivery_pricing(base_cost, delivery_type, package_size, is_intra_area, is_intra_location)
      size_multiplier = get_package_size_multiplier(package_size)
      
      case delivery_type
      when 'fragile'
        fragile_base = base_cost * 1.5 # 50% premium for fragile handling
        fragile_surcharge = 100 # Fixed surcharge for special handling
        ((fragile_base + fragile_surcharge) * size_multiplier).round
      when 'home'
        home_base = if is_intra_area
          base_cost * 1.2 # 20% premium for doorstep delivery within area
        elsif is_intra_location
          base_cost * 1.1 # 10% premium for doorstep delivery within location
        else
          base_cost # Standard inter-location pricing
        end
        (home_base * size_multiplier).round
      when 'office'
        office_discount = 0.75 # 25% discount for office collection
        office_base = base_cost * office_discount
        (office_base * size_multiplier).round
      when 'collection'
        collection_base = base_cost * 1.3 # 30% premium for collection service
        collection_surcharge = 50 # Fixed surcharge for collection logistics
        ((collection_base + collection_surcharge) * size_multiplier).round
      when 'agent'
        # Agent delivery is standardized pricing
        150
      else
        (base_cost * size_multiplier).round
      end
    end
    
    # Get all locations for pricing calculations
    all_locations = Location.all.to_a
    all_delivery_types = ['fragile', 'home', 'office', 'collection', 'agent']
    all_package_sizes = ['small', 'medium', 'large']
    
    puts "  📊 Generating pricing for #{all_locations.count} locations, #{all_delivery_types.count} delivery types, #{all_package_sizes.count} package sizes..."
    
    pricing_count = 0
    
    all_locations.each do |origin_location|
      all_locations.each do |destination_location|
        
        # Calculate base costs based on route type
        if origin_location == destination_location
          # Intra-city pricing
          base_cost = 200
        else
          # Inter-city pricing
          base_cost = calculate_inter_city_cost(origin_location.name, destination_location.name)
        end
        
        # Get areas for this location pair
        origin_areas = Area.where(location: origin_location)
        destination_areas = Area.where(location: destination_location)
        
        origin_areas.each do |origin_area|
          destination_areas.each do |destination_area|
            
            # Determine relationship
            is_intra_area = origin_area.id == destination_area.id
            is_intra_location = origin_area.location_id == destination_area.location_id
            
            all_delivery_types.each do |delivery_type|
              all_package_sizes.each do |package_size|
                
                # Calculate cost for this combination
                calculated_cost = calculate_delivery_pricing(
                  base_cost, 
                  delivery_type, 
                  package_size, 
                  is_intra_area, 
                  is_intra_location
                )
                
                # Create price record
                Price.create!(
                  origin_area: origin_area,
                  destination_area: destination_area,
                  delivery_type: delivery_type,
                  package_size: package_size,
                  cost: calculated_cost
                )
                
                pricing_count += 1
              end
            end
          end
        end
      end
    end
    
    puts "  ✅ Created #{pricing_count} pricing records"
    
    # === SAMPLE PRICING VERIFICATION ===
    puts "  🔍 Sample pricing verification:"
    
    # Sample intra-area pricing
    cbd_area = Area.find_by(name: "CBD")
    if cbd_area
      sample_intra = Price.where(
        origin_area: cbd_area,
        destination_area: cbd_area,
        package_size: 'medium'
      )
      
      sample_intra.each do |price|
        puts "    CBD → CBD (#{price.delivery_type}, medium): KES #{price.cost}"
      end
    end
    
    # Sample inter-location pricing
    nairobi_cbd = Area.find_by(name: "CBD")
    mombasa_island = Area.find_by(name: "Mombasa Island")
    if nairobi_cbd && mombasa_island
      sample_inter = Price.where(
        origin_area: nairobi_cbd,
        destination_area: mombasa_island,
        package_size: 'medium'
      )
      
      sample_inter.each do |price|
        puts "    Nairobi CBD → Mombasa Island (#{price.delivery_type}, medium): KES #{price.cost}"
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
    
    puts "\n🚀 System ready for enhanced package operations!"
    puts "\n💡 Test credentials:"
    puts "  📧 Admin: admin@example.com / Password123"
    puts "  📧 Client: glenwinterg970@gmail.com / Leviathan@Xcode"
    if Rails.env.development?
      puts "  📧 Test: test@example.com / password123"
    end
    
    puts "\n📦 Available delivery types:"
    puts "  🏠 Home Delivery - Direct to recipient address"
    puts "  🏢 Office Delivery - Collect from GLT office"
    puts "  ⚠️  Fragile Delivery - Special handling for delicate items"
    puts "  📦 Collection Service - We collect from your location"
    puts "  👤 Agent Delivery - Agent-to-agent transfer"
    
    puts "\n📏 Package sizes supported:"
    puts "  📦 Small - Documents, accessories, small items"
    puts "  📦 Medium - Books, clothes, electronics"
    puts "  📦 Large - Bulky items, furniture parts (special handling required)"
    
  rescue StandardError => e
    puts "\n❌ Seeding failed with error: #{e.message}"
    puts "📍 Error class: #{e.class}"
    puts "📍 Backtrace: #{e.backtrace.first(5).join("\n")}"
    raise e # Re-raise to trigger rollback
  end
end