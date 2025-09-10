# db/migrate/YYYYMMDDHHMMSS_migrate_to_apk_updates.rb
class MigrateToApkUpdates < ActiveRecord::Migration[7.1]
  def up
    # Add new APK-specific columns
    add_column :app_updates, :apk_url, :string
    add_column :app_updates, :apk_key, :string
    add_column :app_updates, :apk_size, :bigint
    add_column :app_updates, :apk_filename, :string
    
    # Migrate existing data from bundle to APK fields
    AppUpdate.find_each do |update|
      if update.bundle_url.present?
        update.update_columns(
          apk_url: update.bundle_url,
          apk_key: update.bundle_key
        )
      end
    end
    
    # Remove old bundle columns
    remove_column :app_updates, :bundle_url, :string
    remove_column :app_updates, :bundle_key, :string
    
    # Add indexes for better performance
    add_index :app_updates, :apk_key
    
  end
  
  def down
    # Add back bundle columns
    add_column :app_updates, :bundle_url, :string
    add_column :app_updates, :bundle_key, :string
    
    # Migrate data back from APK to bundle fields
    AppUpdate.find_each do |update|
      if update.apk_url.present?
        update.update_columns(
          bundle_url: update.apk_url,
          bundle_key: update.apk_key
        )
      end
    end
    
    # Remove APK columns
    remove_index :app_updates, :apk_key
    remove_index :app_updates, :version
    remove_column :app_updates, :apk_url, :string
    remove_column :app_updates, :apk_key, :string
    remove_column :app_updates, :apk_size, :bigint
    remove_column :app_updates, :apk_filename, :string
  end
end