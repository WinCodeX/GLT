class AddCascadeToBusinessActivitiesPackagesFk < ActiveRecord::Migration[7.0]
  def change
    remove_foreign_key :business_activities, :packages
    add_foreign_key :business_activities, :packages, on_delete: :cascade
  end
end