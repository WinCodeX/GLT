class CreateBusinessActivities < ActiveRecord::Migration[7.0]
  def change
    create_table :business_activities do |t|
      t.references :business, null: false, foreign_key: true, index: true
      t.references :user, null: false, foreign_key: true, index: true
      t.references :target_user, null: true, foreign_key: { to_table: :users }, index: true
      t.references :package, null: true, foreign_key: true, index: true
      
      t.string :activity_type, null: false, index: true
      t.text :description, null: false
      t.json :metadata, default: {}
      
      t.timestamps
    end

    # Add compound indexes for better query performance
    add_index :business_activities, [:business_id, :created_at], order: { created_at: :desc }
    add_index :business_activities, [:business_id, :activity_type]
    add_index :business_activities, [:user_id, :created_at], order: { created_at: :desc }
  end
end