class AddVtUrlToCollections < ActiveRecord::Migration
  def change
    add_column :collections, :vt_url, :string
  end
end
