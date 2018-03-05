object @collection
node(:collection_url) { collection_url(@collection.name) }
node(:collection_name) { @collection.name }
node(:metadata) do
  hash = {}
  collection_show_fields(@collection).each do |field|
    key = field.first[0]
    value = field.first[1].to_s

    hash[key] = value
  end
  hash
end