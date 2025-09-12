# db/migrate/20250912150000_add_resubmission_fields_to_packages.rb
class AddResubmissionFieldsToPackages < ActiveRecord::Migration[7.1]
  def change
    add_column :packages, :resubmission_count, :integer, default: 0
    add_column :packages, :original_state, :string
    add_column :packages, :rejection_reason, :text
    add_column :packages, :rejected_at, :datetime
    add_column :packages, :auto_rejected, :boolean, default: false
    add_column :packages, :resubmitted_at, :datetime
    add_column :packages, :expiry_deadline, :datetime
    add_column :packages, :final_deadline, :datetime
    
    add_index :packages, :resubmission_count
    add_index :packages, :rejected_at
    add_index :packages, :auto_rejected
    add_index :packages, :expiry_deadline
    add_index :packages, :final_deadline
    add_index :packages, [:state, :expiry_deadline]
    add_index :packages, [:state, :final_deadline]
  end
end