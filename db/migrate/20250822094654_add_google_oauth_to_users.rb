class AddGoogleOauthToUsers < ActiveRecord::Migration[7.1]
  def change
    # OAuth provider fields
    add_column :users, :provider, :string
    add_column :users, :uid, :string
    add_column :users, :google_image_url, :string
    add_column :users, :confirmed_at, :datetime
    
    # Indexes for performance
    add_index :users, [:provider, :uid], unique: true
    add_index :users, :provider
    add_index :users, :uid
    add_index :users, :confirmed_at
    
    # Ensure existing users have confirmed_at set
    User.update_all(confirmed_at: Time.current) if User.exists?
  end
end