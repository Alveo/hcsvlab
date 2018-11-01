class CreateItemListProperties < ActiveRecord::Migration
  def change
    create_table :item_list_properties do |t|
      t.string :property
      t.text :value
      t.references :item_list

      t.timestamps
    end
  end
end
