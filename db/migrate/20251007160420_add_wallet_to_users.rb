class AddWalletToUsers < ActiveRecord::Migration[7.0]
  def change
    # Add any user-level wallet tracking if needed
    unless column_exists?(:users, :wallet_enabled)
      add_column :users, :wallet_enabled, :boolean, default: true
      add_column :users, :wallet_setup_completed_at, :datetime
    end
  end
end