class AddCodeToPackagesAndAreaInitials < ActiveRecord::Migration[7.0]
  def change
    # Add code to packages
    add_column :packages, :code, :string, null: false, after: :id
    add_index :packages, :code, unique: true
    
    # Add initials to areas (assuming you have an areas table)
    add_column :areas, :initials, :string, limit: 3
    add_index :areas, :initials, unique: true
    
    # Add counter cache for packages per route
    add_column :packages, :route_sequence, :integer
    add_index :packages, [:origin_area_id, :destination_area_id, :route_sequence]
    
    reversible do |dir|
      dir.up do
        # Set default initials for existing areas (you'll need to customize this)
        execute <<-SQL
          UPDATE areas SET initials = 
            CASE 
              WHEN UPPER(name) LIKE '%NAIROBI%' THEN 'NRB'
              WHEN UPPER(name) LIKE '%KISUMU%' THEN 'KSM'
              WHEN UPPER(name) LIKE '%MOMBASA%' THEN 'MSA'
              WHEN UPPER(name) LIKE '%NAKURU%' THEN 'NKR'
              WHEN UPPER(name) LIKE '%ELDORET%' THEN 'ELD'
              WHEN UPPER(name) LIKE '%THIKA%' THEN 'THK'
              WHEN UPPER(name) LIKE '%MACHAKOS%' THEN 'MCH'
              WHEN UPPER(name) LIKE '%NYERI%' THEN 'NYR'
              ELSE UPPER(LEFT(REGEXP_REPLACE(name, '[^A-Za-z]', '', 'g'), 3))
            END
          WHERE initials IS NULL;
        SQL
        
        # Generate codes for existing packages
        Package.includes(:origin_area, :destination_area).find_each do |package|
          if package.origin_area && package.destination_area
            code = PackageCodeGenerator.new(package).generate
            package.update_columns(code: code, route_sequence: package.calculate_route_sequence)
          end
        end
      end
    end
  end
end