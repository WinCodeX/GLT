# db/seeds.rb
# Production-ready seed file with proper error handling and role management

puts "🌱 Starting to seed the database..."

# Ensure we're in a clean transaction state
ActiveRecord::Base.transaction do
  begin
    
    # === ROLES SETUP (CRITICAL FIRST STEP) ===
    puts "🔐 Setting up roles system..."
    
    # Define all required roles
    REQUIRED_ROLES = %w[client agent rider warehouse admin].freeze
    
    # Create roles with proper error handling
    REQUIRED_ROLES.each do |role_name|
      role = Role.find_or_create_by!(name: role_name) do |r|
        puts "  ✓ Created role: #{role_name}"
      end
      puts "  ✓ Role exists: #{role.name}" if role.persisted?
    end
    
    puts "  📋 Total roles in system: #{Role.count}"
    
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
        # Set initials during creation if supported
        loc.initials = location_data[:initials] if loc.respond_to?(:initials=)
      end
      
      # Update initials if column exists and value is different
      if location.respond_to?(:initials) && location.initials != location_data[:initials]
        location.update!(initials: location_data[:initials])
        puts "  ✓ Updated location: #{location.name} → #{location_data[:initials]}"
      elsif location.respond_to?(:initials)
        puts "  ✓ Location correct: #{location.name} (#{location.initials})"
      else
        puts "  ⚠️  Warning: Location model does not support initials - consider migration"
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
      
      # Other city areas (shortened for brevity but include all from original)
      { name: "Kisumu Central", initials: "KSC", location: "Kisumu" },
      { name: "Eldoret Town", initials: "ETC", location: "Eldoret" },
      { name: "Nakuru Town", initials: "NKT", location: "Nakuru" },
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
        a.initials = area_data[:initials] if a.respond_to?(:initials=)
      end
      
      # Update initials if different
      if area.respond_to?(:initials) && area.initials != area_data[:initials]
        area.update!(initials: area_data[:initials])
        puts "  ✓ Updated area: #{area.name} → #{area.initials} in #{location.name}"
      end
      
      area_records[area_data[:name]] = area
    end
    
    # === USER CREATION HELPER ===
    def self.create_user_safely(email:, password:, first_name:, last_name:, phone_number:, role: nil)
      user = User.find_or_create_by!(email: email) do |u|
        u.password = password
        u.password_confirmation = password
        u.first_name = first_name
        u.last_name = last_name
        u.phone_number = phone_number
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
      phone_number: "+254700000000"
    )
    
    # Create main application users
    create_user_safely(
      email: "glenwinterg970@gmail.com",
      password: "Leviathan@Xcode",
      first_name: "Xs",
      last_name: "",
      phone_number: "+254700000002",
      role: :client
    )
    
    create_user_safely(
      email: "admin@example.com",
      password: "Password123",
      first_name: "Glen",
      last_name: "",
      phone_number: "+254700000003",
      role: :admin
    )
    
    # Development-only test user
    if Rails.env.development?
      create_user_safely(
        email: "test@example.com",
        password: "password123",
        first_name: "Test",
        last_name: "User",
        phone_number: "+254700000001"
      )
      puts "  📧 Dev Test User - Email: test@example.com, Password: password123"
    end
    
    # === AGENTS SETUP ===
    puts "👥 Creating agents..."
    
    agents_data = [
      { name: "GLT Express Hub", phone: "+254700100001", area: "CBD" },
      { name: "Westgate Courier Point", phone: "+254700100002", area: "Westlands" },
      { name: "Karen Shopping Centre Agent", phone: "+254700100003", area: "Karen" },
      { name: "Island Express Centre", phone: "+254700200001", area: "Mombasa Island" },
      { name: "Kisumu Central Agent", phone: "+254700300001", area: "Kisumu Central" },
      { name: "Eldoret Main Hub", phone: "+254700400001", area: "Eldoret Town" },
      { name: "Nakuru Town Centre", phone: "+254700500001", area: "Nakuru Town" },
      { name: "Thika Blue Post Agent", phone: "+254700600001", area: "Thika Town" },
      { name: "Machakos Town Agent", phone: "+254700700001", area: "Machakos Town" }
    ].freeze
    
    agents_data.each do |agent_data|
      area = area_records[agent_data[:area]]
      unless area
        puts "  ⚠️  Warning: Area '#{agent_data[:area]}' not found for agent '#{agent_data[:name]}'"
        next
      end
      
      agent = Agent.find_or_create_by!(name: agent_data[:name]) do |a|
        a.phone = agent_data[:phone]
        a.area = area
        a.user = system_user
        a.active = true if a.respond_to?(:active)
      end
      puts "  ✓ Agent ready: #{agent.name} in #{area.name}, #{area.location.name}"
    end
    
    # === PRICING SETUP ===
    puts "💰 Setting up pricing matrix..."
    
    # Get all locations for pricing calculations
    all_locations = Location.all.to_a
    price_count = 0
    
    all_locations.each do |origin_location|
      all_locations.each do |destination_location|
        
        # Calculate base costs based on route type
        if origin_location == destination_location
          # Intra-city pricing
          base_doorstep_cost = 280
          base_mixed_cost = 230
        else
          # Inter-city pricing with route-specific logic
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
            
            price_count += 3
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
    puts "  💰 Prices: #{Price.count}"
    
    puts "\n🚀 System ready for package operations!"
    
  rescue StandardError => e
    puts "\n❌ Seeding failed with error: #{e.message}"
    puts "📍 Backtrace: #{e.backtrace.first(5).join("\n")}"
    raise e # Re-raise to trigger rollback
  end
end

private

def self.calculate_inter_city_cost(origin, destination)
  major_routes = {
    ["Nairobi", "Mombasa"] => 420,
    ["Nairobi", "Kisumu"] => 400,
    ["Mombasa", "Kisumu"] => 390
  }
  
  route_key = [origin, destination].sort
  major_routes[route_key] || (origin == "Nairobi" || destination == "Nairobi" ? 380 : 370)
end