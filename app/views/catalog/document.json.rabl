object false
node(:files) { @item.documents.collect {|d| catalog_document_url(@collection.name, @item.get_name, d.file_name)} }