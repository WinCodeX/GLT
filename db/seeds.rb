# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end
#["admin", "agent", "rider", "client", "warehouse"].each do |role|
 # Role.find_or_create_by(name: role)
#end

# db/seeds.rb
puts "🌱 Starting to seed the database..."

# Clear existing data in development
if Rails.env.development?
  puts "🧹 Cleaning existing data..."
  Price.destroy_all
  Agent.destroy_all
  Area.destroy_all
  Location.destroy_all
  puts "✅ Cleaned existing data"
end

# Create Locations (Main cities with initials for package codes)
puts "🗺️ Creating main locations (cities with initials)..."

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
]

location_records = {}
locations_data.each do |location_data|
  location = Location.find_or_create_by!(name: location_data[:name]) do |l|
    l.initials = location_data[:initials] if l.respond_to?(:initials)
  end
  location_records[location_data[:name]] = location
  puts "  ✓ Created location: #{location.name} (#{location_data[:initials]})"
end

# Create Areas within Locations (Specific neighborhoods/districts)
puts "🏢 Creating areas within locations..."

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
  
  # Thika Areas
  { name: "Thika Town", initials: "THT", location: "Thika" },
  { name: "Blue Post", initials: "BLP", location: "Thika" },
  { name: "Makongeni", initials: "MKG", location: "Thika" },
  { name: "Kiganjo", initials: "KGJ", location: "Thika" },
  
  # Machakos Areas
  { name: "Machakos Town", initials: "MCT", location: "Machakos" },
  { name: "Athi River", initials: "ATH", location: "Machakos" },
  { name: "Mlolongo", initials: "MLO", location: "Machakos" },
  { name: "Syokimau", initials: "SYK", location: "Machakos" },
  
  # Nyeri Areas
  { name: "Nyeri Town", initials: "NYT", location: "Nyeri" },
  { name: "Karatina", initials: "KRT", location: "Nyeri" },
  { name: "Othaya", initials: "OTH", location: "Nyeri" },
  
  # Meru Areas
  { name: "Meru Town", initials: "MRT", location: "Meru" },
  { name: "Nkubu", initials: "NKU", location: "Meru" },
  { name: "Timau", initials: "TMU", location: "Meru" },
  
  # Kisii Areas
  { name: "Kisii Town", initials: "KST", location: "Kisii" },
  { name: "Suneka", initials: "SNK", location: "Kisii" },
  { name: "Keroka", initials: "KRK", location: "Kisii" }
]

area_records = {}
areas_data.each do |area_data|
  location = location_records[area_data[:location]]
  if location.nil?
    puts "  ⚠️  Warning: Location '#{area_data[:location]}' not found for area '#{area_data[:name]}'"
    next
  end
  
  area = Area.find_or_create_by!(name: area_data[:name], location: location) do |a|
    a.initials = area_data[:initials]
  end
  area_records[area_data[:name]] = area
  puts "  ✓ Created area: #{area.name} (#{area.initials}) in #{location.name}"
end

# Create system user for agents (required by schema)
puts "👤 Creating system user for agents..."
system_user = User.find_or_create_by!(email: "system@glt.co.ke") do |u|
  u.password = "SecureSystemPassword123!"
  u.password_confirmation = "SecureSystemPassword123!"
  u.first_name = "GLT"
  u.last_name = "System"
  u.phone_number = "+254700000000"
end
puts "  ✓ Created/found system user: #{system_user.email}"

# Create test user for development
if Rails.env.development?
  puts "👤 Creating test user..."
  test_user = User.find_or_create_by!(email: "test@example.com") do |u|
    u.password = "password123"
    u.password_confirmation = "password123"
    u.first_name = "Test"
    u.last_name = "User"
    u.phone_number = "+254700000001"
  end
  puts "  ✓ Created test user: #{test_user.email}"
  puts "  📧 Email: test@example.com"
  puts "  🔑 Password: password123"
end

# Create Agents (they belong directly to areas per schema)
puts "👥 Creating agents..."

agents_data = [
  # Nairobi Agents
  { name: "GLT Express Hub", phone: "+254700100001", area: "CBD" },
  { name: "Westgate Courier Point", phone: "+254700100002", area: "Westlands" },
  { name: "Karen Shopping Centre Agent", phone: "+254700100003", area: "Karen" },
  { name: "Kilimani Plaza Pickup", phone: "+254700100004", area: "Kilimani" },
  { name: "Kasarani Express Station", phone: "+254700100005", area: "Kasarani" },
  { name: "Embakasi Delivery Hub", phone: "+254700100006", area: "Embakasi" },
  
  # Mombasa Agents
  { name: "Island Express Centre", phone: "+254700200001", area: "Mombasa Island" },
  { name: "Nyali Cinemax Agent", phone: "+254700200002", area: "Nyali" },
  { name: "Bamburi Mtambo Pickup", phone: "+254700200003", area: "Bamburi" },
  { name: "Diani Beach Agent", phone: "+254700200004", area: "Diani" },
  
  # Kisumu Agents
  { name: "Kisumu Central Agent", phone: "+254700300001", area: "Kisumu Central" },
  { name: "Kondele Market Hub", phone: "+254700300002", area: "Kondele" },
  { name: "Mamboleo Express", phone: "+254700300003", area: "Mamboleo" },
  
  # Eldoret Agents
  { name: "Eldoret Main Hub", phone: "+254700400001", area: "Eldoret Town" },
  { name: "Pioneer Campus Agent", phone: "+254700400002", area: "Pioneer" },
  { name: "Langas Express Point", phone: "+254700400003", area: "Langas" },
  
  # Nakuru Agents
  { name: "Nakuru Town Centre", phone: "+254700500001", area: "Nakuru Town" },
  { name: "Lanet Express Point", phone: "+254700500002", area: "Lanet" },
  { name: "Naivasha Hub", phone: "+254700500003", area: "Naivasha" },
  
  # Thika Agents
  { name: "Thika Blue Post Agent", phone: "+254700600001", area: "Thika Town" },
  { name: "Makongeni Pickup Point", phone: "+254700600002", area: "Makongeni" },
  
  # Machakos Agents
  { name: "Machakos Town Agent", phone: "+254700700001", area: "Machakos Town" },
  { name: "Athi River Express", phone: "+254700700002", area: "Athi River" },
  { name: "Syokimau Airport Hub", phone: "+254700700003", area: "Syokimau" },
  
  # Other Cities
  { name: "Nyeri Central Agent", phone: "+254700800001", area: "Nyeri Town" },
  { name: "Meru Main Hub", phone: "+254700900001", area: "Meru Town" },
  { name: "Kisii Town Agent", phone: "+254701000001", area: "Kisii Town" }
]

agents_data.each do |agent_data|
  area = area_records[agent_data[:area]]
  if area.nil?
    puts "  ⚠️  Warning: Area '#{agent_data[:area]}' not found for agent '#{agent_data[:name]}'"
    next
  end
  
  agent = Agent.find_or_create_by!(name: agent_data[:name]) do |a|
    a.phone = agent_data[:phone]
    a.area = area
    a.user = system_user
    a.active = true if a.respond_to?(:active)
  end
  puts "  ✓ Created agent: #{agent.name} in #{area.name}, #{area.location.name}"
end

# Create Prices (Location to Location pricing)
puts "💰 Creating prices (location-based pricing)..."

all_locations = Location.all.to_a
price_count = 0

# Create pricing based on location-to-location routes
all_locations.each do |origin_location|
  all_locations.each do |destination_location|
    
    # Determine base cost based on route type
    if origin_location == destination_location
      # Intra-city pricing (same location)
      base_doorstep_cost = rand(250..300)
      base_mixed_cost = rand(200..250)
    else
      # Inter-city pricing
      base_cost = case [origin_location.name, destination_location.name]
      when -> { _1.include?("Nairobi") && _1.include?("Mombasa") }
        420 # Major route
      when -> { _1.include?("Nairobi") && _1.include?("Kisumu") }
        400 # Major route
      when -> { _1.include?("Nairobi") }
        380 # From/to Nairobi
      when -> { _1.include?("Mombasa") && _1.include?("Kisumu") }
        390 # Major coastal-inland
      when -> { _1.include?("Thika") && _1.include?("Nairobi") }
        330 # Close cities
      when -> { _1.include?("Machakos") && _1.include?("Nairobi") }
        340 # Close cities
      else
        370 # Other inter-city routes
      end
      
      # Add variation for realism
      variation = rand(-20..30)
      base_doorstep_cost = base_cost + variation
      base_mixed_cost = ((base_doorstep_cost + 150) / 2).round
    end
    
    # Get all area combinations for this location pair
    origin_areas = Area.where(location: origin_location)
    destination_areas = Area.where(location: destination_location)
    
    origin_areas.each do |origin_area|
      destination_areas.each do |destination_area|
        # Create Doorstep delivery price
        Price.find_or_create_by!(
          origin_area: origin_area,
          destination_area: destination_area,
          delivery_type: 'doorstep'
        ) do |p|
          # Add small area-specific variation
          area_variation = rand(-10..10)
          p.cost = [[base_doorstep_cost + area_variation, 420].min, 250].max
        end
        price_count += 1

        # Create Agent pickup price (always 150)
        Price.find_or_create_by!(
          origin_area: origin_area,
          destination_area: destination_area,
          delivery_type: 'agent'
        ) do |p|
          p.cost = 150
        end
        price_count += 1

        # Create Mixed delivery price
        Price.find_or_create_by!(
          origin_area: origin_area,
          destination_area: destination_area,
          delivery_type: 'mixed'
        ) do |p|
          area_variation = rand(-5..5)
          p.cost = [[base_mixed_cost + area_variation, 300].min, 200].max
        end
        price_count += 1
      end
    end
  end
end

puts "  ✓ Created #{price_count} price entries"

# Summary
puts "\n🎉 Seeding completed successfully!"
puts "📊 Summary:"
puts "  🗺️ Locations (Cities): #{Location.count}"
puts "  🏢 Areas (Neighborhoods): #{Area.count}"
puts "  👥 Agents: #{Agent.count}"
puts "  💰 Prices: #{Price.count}"
puts "  👤 Users: #{User.count}"

puts "\n💡 Key test data:"
puts "  🏢 Nairobi location (NRB) with CBD area"
puts "  🏪 GLT Express Hub agent in CBD"
puts "  💰 Doorstep prices: KSh 250-420"
puts "  💰 Agent pickup: KSh 150 (fixed)"
puts "  💰 Mixed delivery: KSh 200-300"
puts "  📱 Ready for package creation testing!"

# Display location initials for package code reference
puts "\n📋 Location initials for package codes:"
Location.all.each do |location|
  initials = locations_data.find { |l| l[:name] == location.name }&.dig(:initials) || "N/A"
  puts "  #{location.name}: #{initials}"
end

# Display some sample prices for verification
puts "\n📋 Sample pricing (location-based):"
nairobi = Location.find_by(name: "Nairobi")
kisumu = Location.find_by(name: "Kisumu")
cbd_area = Area.find_by(initials: "CBD")
westlands_area = Area.find_by(initials: "WTL")
kisumu_central = Area.find_by(initials: "KSC")

if cbd_area && westlands_area && kisumu_central
  [
    ["Nairobi (CBD) to Nairobi (Westlands) - Doorstep", Price.find_by(origin_area: cbd_area, destination_area: westlands_area, delivery_type: 'doorstep')&.cost],
    ["Nairobi (CBD) to Nairobi (CBD) - Agent", Price.find_by(origin_area: cbd_area, destination_area: cbd_area, delivery_type: 'agent')&.cost],
    ["Nairobi (CBD) to Kisumu (Central) - Doorstep", Price.find_by(origin_area: cbd_area, destination_area: kisumu_central, delivery_type: 'doorstep')&.cost],
    ["Nairobi (CBD) to Kisumu (Central) - Agent", Price.find_by(origin_area: cbd_area, destination_area: kisumu_central, delivery_type: 'agent')&.cost]
  ].each do |route, price|
    puts "  #{route}: KSh #{price || 'N/A'}"
  end
end

puts "\n🌟 Package code examples:"
puts "  📦 Nairobi to Kisumu: NRB-001-KSM"
puts "  📦 Within Nairobi: NRB-001"
puts "  📦 Mombasa to Eldoret: MSA-001-ELD"
puts "  📦 Within Mombasa: MSA-001"

puts "\n🚀 Ready to test package creation with clean city codes!"