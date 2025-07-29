class AddAgentReferencesToPrices < ActiveRecord::Migration[7.1]
  def change
    add_reference :prices, :origin_agent, foreign_key: { to_table: :agents }
    add_reference :prices, :destination_agent, foreign_key: { to_table: :agents }
    add_column :prices, :delivery_type, :string
  end
end