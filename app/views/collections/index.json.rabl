object false
node(:num_collections) { @collections.size }
node(:collections) { @collections.collect {|c| collection_url(c.name)} }
node(:directories) { @collections.collect {|c| collection_url(c.name)} }
