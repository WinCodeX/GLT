class RenameUserIdToOwnerIdInBusinesses < ActiveRecord::Migration[7.1]
 def change
  rename_column :businesses, :user_id, :owner_id
end
end
