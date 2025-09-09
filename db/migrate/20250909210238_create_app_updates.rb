class CreateAppUpdates < ActiveRecord::Migration[7.0]
  def change
    create_table :app_updates do |t|
      t.string :version, null: false
      t.string :update_id, null: false, index: { unique: true }
      t.string :runtime_version, default: '1.0.0'
      t.string :bundle_url
      t.string :bundle_key
      t.text :changelog, array: true, default: []
      t.boolean :published, default: false
      t.boolean :force_update, default: false
      t.datetime :published_at
      t.json :assets, default: []
      t.text :description
      t.integer :download_count, default: 0

      t.timestamps
    end

    add_index :app_updates, [:published, :created_at]
    add_index :app_updates, :version
  end
end