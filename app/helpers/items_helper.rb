module ItemsHelper

  # Kick off the addition of an item
  # 
  # attrs is expected to contain at least something like:
  # {
  # "item_name"=>"bombastic", 
  # "item_title"=>"Bombastic Man",
  # "additional_key"=>["dc:creator", "dc:somethingElse"],
  # "additional_value"=>["Andy", "Thing"],
  # }
  # 
  # This will either come from params via web_add_item or another object via worker/import_extracted_zip
  # 
  def add_item(attrs, item_name, collection)
    Rails.logger.debug("Called add_item with:")
    Rails.logger.debug(attrs)
    Rails.logger.debug(item_name)
    Rails.logger.debug(collection)

    # Raise an exception if required fields are empty
    validate_required_web_fields(attrs, {:item_name => 'item name', :item_title => 'item title'})

    additional_metadata = validate_item_additional_metadata(attrs)
    # Get a hash of metadata
    json_ld = construct_item_json_ld(collection, item_name, attrs[:item_title], additional_metadata)

    # Write the item metadata to an rdf file and ingest the file
    processed_items = process_items(collection.name, collection.corpus_dir, {:items => [{'metadata' => json_ld}]})

    add_item_core(collection, processed_items[:successes])
  end

  # Add a document
  # 
  # attrs is expected to contain at least something like:
  # 
  # {
  # "document_file"=> ActionDispatch::Http::UploadedFile or path on disk,
  # "language"=>"eng - English",
  # "collection"=>"aftestcollection1",
  # "itemId"=>"bs_n_4"
  # }
  def add_document(attrs, item, filepath)
    additional_metadata = validate_document_additional_metadata(attrs)
    filepath = upload_document_from_import(item.collection.corpus_dir, filepath, item.collection.name)
    json_ld = construct_document_json_ld(item.collection, item, attrs[:language], filepath, additional_metadata)
    add_document_core(item.collection, item, json_ld, filepath)
  end

  # Creates a file at the specified path with the given content
  def create_file(file_path, content)
    FileUtils.mkdir_p(File.dirname file_path)
    File.open(file_path, 'w') do |file|
      file.puts content
    end
  end

  # Coverts JSON-LD formatted collection metadata and converts it to RDF
  # def convert_json_metadata_to_rdf(json_metadata)
  #   graph = RDF::Graph.new << JSON::LD::API.toRDF(json_metadata)
  #   # graph.dump(:ttl, prefixes: {foaf: "http://xmlns.com/foaf/0.1/"})
  #   graph.dump(:ttl)
  # end

  # Writes the collection manifest as JSON and the metadata as .n3 RDF
  def create_metadata_and_manifest(collection_name, collection_rdf, collection_manifest={"collection_name" => collection_name, "files" => {}})

    corpus_dir = File.join(Rails.application.config.api_collections_location, collection_name)
    FileUtils.mkdir_p(corpus_dir)

    # metadata_file_path = File.join(Rails.application.config.api_collections_location,  collection_name + '.n3')
    # File.open(metadata_file_path, 'w') do |file|
    #   file.puts collection_rdf
    # end

    manifest_file_path = File.join(corpus_dir, MANIFEST_FILE_NAME)
    File.open(manifest_file_path, 'w') do |file|
      file.puts(collection_manifest.to_json)
    end

    corpus_dir
  end

  # Creates a combined metadata.rdf file and returns the path of that file.
  # The file name takes the form of 'item1-item2-itemN-metadata.rdf'
  def create_combined_item_rdf(corpus_dir, item_names, item_rdf)
    create_item_rdf(corpus_dir, item_names.join("-"), item_rdf)
  end

  # creates an item-metadata.rdf file and returns the path of that file
  def create_item_rdf(corpus_dir, item_name, item_rdf)
    filename = File.join(corpus_dir, item_name + '-metadata.rdf')
    create_file(filename, item_rdf)
    filename
  end

  # Renders the given error message as JSON
  def respond_with_error(message, status_code)
    respond_to do |format|
      response = {:error => message}
      response[:failures] = params[:failures] unless params[:failures].blank?
      format.any {render :json => response.to_json, :status => status_code}
    end
  end

  # Adds the given message to the failures param
  def add_failure_response(message)
    params[:failures] = [] if params[:failures].nil?
    params[:failures].push(message)
  end

  # Uploads a document given as json content
  def upload_document_using_json(corpus_dir, file_basename, json_content)
    absolute_filename = File.join(corpus_dir, file_basename)
    Rails.logger.debug("Writing uploaded document contents to new file #{absolute_filename}")
    create_file(absolute_filename, json_content)
    absolute_filename
  end

  # Uploads a document given as a http multipart uploaded file or responds with an error if appropriate
  def upload_document_using_multipart(corpus_dir, file_basename, file, collection_name)
    absolute_filename = File.join(corpus_dir, file_basename)
    if !file.is_a? ActionDispatch::Http::UploadedFile
      raise ResponseError.new(412), "Error in file parameter."
    elsif file.blank? or file.size == 0
      raise ResponseError.new(412), "Uploaded file #{file_basename} is not present or empty."
    else
      Rails.logger.debug("Copying uploaded document file from #{file.tempfile} to #{absolute_filename}")
      FileUtils.cp file.tempfile, absolute_filename
      absolute_filename
    end
  end

  def upload_document_from_import(corpus_dir, file, collection_name)
    file_basename = File.basename(file)
    absolute_filename = File.join(corpus_dir, file_basename)
    if !File.exist?(file)
      raise ResponseError.new(412), "Error in file parameter."
    elsif file.blank? or file.size == 0
      raise ResponseError.new(412), "Uploaded file #{file_basename} is not present or empty."
    else
      Rails.logger.debug("Copying uploaded document file from #{file} to #{absolute_filename}")
      FileUtils.cp file, absolute_filename
      absolute_filename
    end
  end

  # Processes the metadata for each item in the supplied request parameters
  # Returns a hash containing :successes and :failures of processed items
  def process_items(collection_name, corpus_dir, request_params, uploaded_files=[])
    items = []
    failures = []
    request_params[:items].each do |item|
      item = process_item_documents_and_update_graph(corpus_dir, item)
      item = update_item_graph_with_uploaded_files(uploaded_files, item)
      begin
        validate_jsonld(item["metadata"])
        item["metadata"] = override_is_part_of_corpus(item["metadata"], collection_name)
        item_hash = write_item_metadata(corpus_dir, item) # Convert item metadata from JSON to RDF
        items.push(item_hash)
      rescue ResponseError
        failures.push('Unknown item contains invalid metadata')
      end
    end
    process_item_failures(failures) unless failures.empty?
    raise ResponseError.new(400), "No items were added" if items.blank?
    {:successes => items, :failures => failures}
  end

  # Adds failure message to response params
  def process_item_failures(failures)
    failures.each do |message|
      add_failure_response(message)
    end
  end

  # Uploads any documents in the item metadata and returns a copy of the item metadata with its metadata graph updated
  def process_item_documents_and_update_graph(corpus_dir, item_metadata)
    unless item_metadata["documents"].nil?
      item_metadata["documents"].each do |document|
        doc_abs_path = upload_document_using_json(corpus_dir, document["identifier"], document["content"])
        unless doc_abs_path.nil?
          item_metadata['metadata']['@graph'] = update_document_source_in_graph(item_metadata['metadata']['@graph'], document["identifier"], doc_abs_path)
        end
      end
    end
    item_metadata
  end

  # Updates the metadata graph for the given item
  # Returns a copy of the item with the document sourcs in the graph updates to the path of an uploaded file when appropriate
  def update_item_graph_with_uploaded_files(uploaded_files, item_metadata)
    uploaded_files.each do |file_path|
      item_metadata['metadata']['@graph'] = update_document_source_in_graph(item_metadata['metadata']['@graph'], File.basename(file_path), file_path)
    end
    item_metadata
  end

  # Updates the source of a specific document in the JSON formatted Item graph
  def update_document_source_in_graph(jsonld_graph, doc_identifier, doc_source)
    jsonld_graph.each do |graph_entry|
      # Handle documents nested within item metadata
      ["ausnc:document", MetadataHelper::DOCUMENT].each do |ausnc_doc|
        if graph_entry.has_key?(ausnc_doc)
          if graph_entry[ausnc_doc].is_a? Array
            graph_entry[ausnc_doc].each do |doc|
              update_doc_source(doc, doc_identifier, doc_source) # handle array of doc hashes
            end
          else
            update_doc_source(graph_entry[ausnc_doc], doc_identifier, doc_source) # handle single doc hash
          end
        end
      end

      # Handle documents contained in the same hash as item metadata
      update_doc_source(graph_entry, doc_identifier, doc_source)
    end
    jsonld_graph
  end

  #
  # Returns a hash containing the metadata for a document source
  #
  def format_document_source_metadata(doc_source)
    # Escape any filename symbols which need to be replaced with codes to form a valid URI
    JsonLdHelper.format_document_source_metadata(doc_source)
  end

  # Updates the source of a specific document
  def update_doc_source(doc_metadata, doc_identifier, doc_source)
    if doc_metadata['dc:identifier'] == doc_identifier || doc_metadata['dcterms:identifier'] == doc_identifier || doc_metadata[MetadataHelper::IDENTIFIER.to_s] == doc_identifier
      formatted_source_path = format_document_source_metadata(doc_source)
      doc_has_source = false
      # Replace any existing document source with the formatted one or add one in if there aren't any existing
      ['dc:source', 'dcterms:source', MetadataHelper::SOURCE.to_s].each do |source|
        if doc_metadata.has_key?(source)
          doc_metadata.update({source => formatted_source_path})
          doc_has_source = true
        end
      end
      doc_metadata.update({MetadataHelper::SOURCE.to_s => formatted_source_path}) unless doc_has_source
    end
  end

  # Returns a cleansed copy of params for the add item api
  def cleanse_params(request_params)
    request_params[:items] = parse_str_to_json(request_params[:items], 'JSON item metadata is ill-formatted')
    request_params[:file] = [] if request_params[:file].nil?
    request_params[:file] = [request_params[:file]] unless request_params[:file].is_a? Array
    request_params
  end

  # Parses a given JSON string and raises an exception with the given message if a ParserError occurs
  def parse_str_to_json(json_string, parser_error_msg)
    if json_string.is_a? String
      begin
        json_string = JSON.parse(json_string)
      rescue JSON::ParserError
        raise ResponseError.new(400), parser_error_msg
      end
    end
    json_string
  end

  # Processes files uploaded as part of a multipart request
  def process_uploaded_files(corpus_dir, collection_name, files)
    uploaded_files = []
    files.each do |uploaded_file|
      uploaded_files.push(upload_document_using_multipart(corpus_dir, uploaded_file.original_filename, uploaded_file, collection_name))
    end
    uploaded_files
  end

  # Ingests a list of items
  def ingest_items(corpus_dir, items)
    items_ingested = []
    items.each do |item|
      ingest_one(corpus_dir, item[:rdf_file])
      item[:identifier].each {|id| items_ingested.push(id)}
    end
    items_ingested
  end

  # Write item JSON metadata to RDF file and returns a hash containing :identifier, :rdf_file
  def write_item_metadata(corpus_dir, item_json)
    rdf_metadata = MetadataHelper::json_to_rdf_graph(item_json["metadata"]).dump(:ttl)
    item_identifiers = get_item_identifiers(item_json["metadata"])
    if item_identifiers.count == 1
      rdf_file = create_item_rdf(corpus_dir, item_identifiers.first, rdf_metadata)
    else
      rdf_file = create_combined_item_rdf(corpus_dir, item_identifiers, rdf_metadata)
    end

    {:identifier => item_identifiers, :rdf_file => rdf_file}
  end

  # Updates the item in Solr by re-indexing that item
  def update_item_in_solr(item)
    # ToDo: refactor this workaround into a proper test mock/stub
    if Rails.env.test?
      json = {:cmd => "index", :arg => "#{item.id}"}
      Solr_Worker.new.on_message(JSON.generate(json).to_s)
    else
      stomp_client = Stomp::Client.open "#{STOMP_CONFIG['adapter']}://#{STOMP_CONFIG['host']}:#{STOMP_CONFIG['port']}"
      reindex_item_to_solr(item.id, stomp_client)
      stomp_client.close
    end
  end

  def update_item_in_sesame(new_metadata, collection)
    stomp_client = Stomp::Client.open "#{STOMP_CONFIG['adapter']}://#{STOMP_CONFIG['host']}:#{STOMP_CONFIG['port']}"

    packet = {
      :cmd => "update_item_in_sesame",
      :arg => {
        :new_metadata => new_metadata,
        :collection_id => collection.id
      }
    }

    stomp_client.publish('alveo.solr.worker', packet.to_json)
    stomp_client.close
  end

  # Returns a collection repository from the Sesame server
  def get_sesame_repository(collection)
    server = RDF::Sesame::HcsvlabServer.new(SESAME_CONFIG["url"].to_s)
    server.repository(collection.name)
  end

  # Inserts the statements of the graph into the Sesame repository
  def insert_graph_into_repository(graph, repository)
    graph.each_statement {|statement| repository.insert(statement)}
  end

  #
  # Gets the document URI from Sesame
  # URI is obtained by querying the item's RDF documents for a doc with a metadata ID matching the doc filename in the db
  #
  def get_doc_subject_uri_from_sesame(document, repository)
    document_uri = nil
    is_doc_found = false

    item_documents = RDF::Query.execute(repository) do
      pattern [RDF::URI.new(document.item.uri), MetadataHelper::DOCUMENT, :object]
    end
    item_documents.each do |doc|
      doc_ids = RDF::Query.execute(repository) do
        pattern [doc[:object], MetadataHelper::IDENTIFIER, :doc_id]
      end
      doc_ids.each do |doc_id|
        if doc_id[:doc_id] == document.file_name
          document_uri = doc[:object]
          is_doc_found = true

          break
        end
      end

      if is_doc_found
        break
      end
    end
    # raise 'Could not obtain document URI from Sesame' if document_uri.nil?
    if document_uri.nil?
      logger.warn "get_doc_subject_uri_from_sesame: Could not obtain document[db_id=#{document.id}] URI from Sesame"
    end

    document_uri
  end

  # Removes a document from the database, filesystem, Sesame and Solr
  def remove_document(document, collection)
    delete_file(document.file_path)
    delete_document_from_sesame(document, get_sesame_repository(collection))
    delete_document_from_solr(document.id)
    document.destroy # Remove document and document audits from database
  end

  # Removes an item and its documents from the database, filesystem, Sesame and Solr
  def remove_item(item, collection)
    delete_item_from_filesystem(item)
    delete_from_sesame(item, collection)
    delete_item_from_solr(item[:handle])
    item.destroy # Remove from database (item, its documents and their document audits)
  end

  # Removes the metadata and document files for an item
  def delete_item_from_filesystem(item)
    item_name = item.get_name
    delete_file(File.join(item.collection.corpus_dir, "#{item_name}-metadata.rdf"))
    item.documents.each do |document|
      delete_file(document.file_path)
    end
  end

  # Deletes an item and its documents from Sesame
  def delete_from_sesame(item, collection)
    stomp_client = Stomp::Client.open "#{STOMP_CONFIG['adapter']}://#{STOMP_CONFIG['host']}:#{STOMP_CONFIG['port']}"

    packet = {
      :cmd => "delete_item_from_sesame",
      :arg => {
        :item_id => item.id
      }
    }
    stomp_client.publish('alveo.solr.worker', packet.to_json)
    stomp_client.close
  end

  # Attempts to delete a file or logs any exceptions raised
  def delete_file(file_path)
    begin
      File.delete(file_path)
    rescue => e
      Rails.logger.error e.inspect
      false
    end
  end

  # KL
  # Writes a metadata RDF graph
  # def write_metadata_graph(metadata_graph, file_path, format=:ttl)
  #   File.open(file_path, 'w') do |file|
  #     file.puts metadata_graph.dump(format)
  #   end
  # end

  # Returns a copy of the combination of the given graphs
  def combine_graphs(graph1, graph2)
    temp_graph = RDF::Graph.new
    temp_graph << graph1
    temp_graph << graph2
    temp_graph
  end

  # Updates an old graph with the statements of a new graph
  #  Any statements in the old graph which have a matching subject and predicate as those in the new graph are deleted
  #  to ensure the graph is updated rather than appended to.
  def update_graph(old_graph, new_graph)
    temp_graph = combine_graphs(old_graph, new_graph)
    new_graph.each do |new_statement|
      matches = RDF::Query.execute(old_graph) {pattern [new_statement.subject, new_statement.predicate, :object]}
      matches.each do |match|
        # when combining graphs the resulting graph only contains distinct statements, so don't delete any fully matching statements
        unless match[:object] == new_statement.object
          temp_graph.delete([new_statement.subject, new_statement.predicate, match[:object]])
        end
      end
    end
    temp_graph
  end

  # Prints the statements of the graph to screen for easier inspection
  def inspect_graph_statements(graph)
    graph.each {|statement| puts statement.inspect}
  end

  # Prints the RDF statements in a collection repository for easier inspection
  def inspect_repository_statements(collection)
    inspect_graph_statements(get_sesame_repository(collection))
  end

  # Formats the collection metadata given as part of the update collection API request
  # Returns an RDF graph of the updated/replaced collection metadata
  def format_update_collection_metadata(collection, new_jsonld_metadata, replace)
    new_jsonld_metadata["@id"] = collection.uri # Collection URI not allowed to change
    replacing_metadata = (replace == true) || (replace.is_a? String and replace.downcase == 'true')
    new_metadata = RDF::Graph.new << JSON::LD::API.toRDF(new_jsonld_metadata)
    if replacing_metadata
      return new_metadata
    else
      return update_graph(collection.rdf_graph, new_metadata)
    end
  end

  # Formats the item metadata given as part of the update item API request
  # Returns an RDF graph of the updated item metadata
  def format_update_item_metadata(item, metadata)
    metadata["@id"] = item.uri # Overwrite the item subject URI
    new_metadata = RDF::Graph.new << JSON::LD::API.toRDF(metadata)
    item_subject = RDF::URI.new(item.uri)
    # Remove any changes to un-editable metadata fields
    dc_id_query = RDF::Query.new do
      pattern [item_subject, MetadataHelper::IDENTIFIER, :obj_identifier]
    end
    new_metadata.query(dc_id_query).distinct.each do |solution|
      new_metadata.delete([item_subject, MetadataHelper::IDENTIFIER, solution[:obj_identifier]])
    end
    new_metadata
  end

  # Returns an Alveo formatted collection full URL
  def format_collection_url(collection_name)
    Rails.application.routes.url_helpers.collection_url(collection_name)
  end

  # Returns an Alevo formatted item full URL
  def format_item_url(collection_name, item_name)
    Rails.application.routes.url_helpers.catalog_url(collection_name, item_name)
  end

  # Retuns an Alveo formatted document full URL
  def format_document_url(collection_name, item_name, document_name)
    Rails.application.routes.url_helpers.catalog_document_url(collection_name, item_name, document_name)
  end

  # Overrides the jsonld is_part_of_corpus with the collection's Alveo url
  def override_is_part_of_corpus(item_json_ld, collection_name)
    item_json_ld["@graph"].each do |node|
      is_doc = node["@type"] == MetadataHelper::DOCUMENT.to_s || node["@type"] == MetadataHelper::FOAF_DOCUMENT.to_s
      part_of_exists= false
      unless is_doc
        ['dcterms:isPartOf', MetadataHelper::IS_PART_OF.to_s].each do |is_part_of|
          if node.has_key?(is_part_of)
            node[is_part_of]["@id"] = format_collection_url(collection_name)
            part_of_exists = true
          end
        end
        unless part_of_exists
          node[MetadataHelper::IS_PART_OF.to_s] = {"@id" => format_collection_url(collection_name)}
        end
      end
    end
    item_json_ld
  end

  # Updates the @ids found in the JSON-LD to be the alveo catalog url
  def update_ids_in_jsonld(jsonld_metadata, collection)
    # NOTE: it is assumed that the metadata will contain only items at the outermost level and documents nested within them
    jsonld_metadata["@graph"].each do |item_metadata|
      item_id = MetadataHelper::get_dc_identifier(item_metadata)
      item_metadata = MetadataHelper::update_jsonld_item_id(item_metadata, collection.name) # Update item @ids
      item_metadata = update_document_ids_in_item(item_metadata, collection.name, item_id) # Update document @ids
      # Update display document and indexable document @ids
      doc_types = ["hcsvlab:display_document", MetadataHelper::DISPLAY_DOCUMENT.to_s, "hcsvlab:indexable_document", MetadataHelper::INDEXABLE_DOCUMENT]
      doc_types.each do |doc_type|
        if item_metadata.has_key?(doc_type)
          doc_short_id = item_metadata[doc_type]["@id"]
          item_metadata[doc_type]["@id"] = format_document_url(collection.name, item_id, doc_short_id)
        end
      end
    end
    jsonld_metadata
  end

  # #Updates the @id of a collection in JSON-LD to the Alveo catalog URL for that collection
  # def update_jsonld_collection_id(collection_metadata, collection_name)
  #   collection_metadata["@id"] = format_collection_url(collection_name)
  #   collection_metadata
  #   # MetadataHelper::update_jsonld_collection_id(collection_metadata, collection_name)
  # end


  # # Updates the @id of an item in JSON-LD to the Alveo catalog URL for that item
  # def update_jsonld_item_id(item_metadata, collection_name)
  #   item_id = get_dc_identifier(item_metadata)
  #   item_metadata["@id"] = format_item_url(collection_name, item_id) unless item_id.nil?
  #   item_metadata
  # end

  # Updates the @id of an document in JSON-LD to the Alveo catalog URL for that document
  def update_jsonld_document_id(document_metadata, collection_name, item_name)
    doc_id = MetadataHelper::get_dc_identifier(document_metadata)
    document_metadata["@id"] = format_document_url(collection_name, item_name, doc_id) unless doc_id.nil?
    document_metadata
  end

  # Updates the @id of documents within items in JSON-LD to the Alveo catalog URL for those documents
  def update_document_ids_in_item(item_metadata, collection_name, item_name)
    ['ausnc:document', MetadataHelper::DOCUMENT.to_s].each do |doc_predicate|
      if item_metadata.has_key?(doc_predicate)
        if item_metadata[doc_predicate].is_a? Array # When "ausnc:document" contains an array of document hashes
          item_metadata[doc_predicate].each do |document_metadata|
            document_metadata = update_jsonld_document_id(document_metadata, collection_name, item_name)
          end
        else # When "ausnc:document" contains a single document hash
          item_metadata[doc_predicate] = update_jsonld_document_id(item_metadata[doc_predicate], collection_name, item_name)
        end
      end
    end
    item_metadata
  end

  # Performs add document validations and returns the formatted metadata with the automatically generated metadata fields
  def format_and_validate_add_document_request(corpus_dir, collection, item, doc_metadata, doc_filename, doc_content, uploaded_file)
    validate_add_document_request(corpus_dir, collection, doc_metadata, doc_filename, doc_content, uploaded_file)
    doc_metadata = format_add_document_metadata(corpus_dir, collection, item, doc_metadata, doc_filename, doc_content, uploaded_file)
    validate_jsonld(doc_metadata)
    validate_document_source(doc_metadata)
    doc_metadata
  end

  # Format the add document metadata and add doc to file system
  def format_add_document_metadata(corpus_dir, collection, item, document_metadata, document_filename, document_content, uploaded_file)
    # Update the document @id to the Alveo catalog URI
    document_metadata = update_jsonld_document_id(document_metadata, collection.name, item.get_name)
    processed_file = nil
    unless uploaded_file.nil?
      processed_file = upload_document_using_multipart(corpus_dir, uploaded_file.original_filename, uploaded_file, collection.name)
    end
    unless document_content.blank?
      processed_file = upload_document_using_json(corpus_dir, document_filename, document_content)
    end
    update_doc_source(document_metadata, document_filename, processed_file) unless processed_file.nil?
    document_metadata
  end

  # Creates a document in the database from Json-ld document metadata
  def create_document(item, document_json_ld)
    expanded_metadata = JSON::LD::API.expand(document_json_ld).first
    file_path = URI(expanded_metadata[MetadataHelper::SOURCE.to_s].first['@id']).path
    file_name = File.basename(file_path)
    doc_type = expanded_metadata[MetadataHelper::TYPE.to_s]
    doc_type = doc_type.first['@value'] unless doc_type.nil?
    document = item.documents.find_or_initialize_by_file_name(file_name)
    if document.new_record?
      begin
        document.file_path = file_path
        document.doc_type = doc_type
        document.mime_type = mime_type_lookup(file_name)
        document.item = item
        document.item_id = item.id
        document.save
        logger.info "#{doc_type} Document = #{document.id.to_s}" unless Rails.env.test?
      rescue Exception => e
        logger.error("Error creating document: #{e.message}")
      end
    else
      raise ResponseError.new(412), "A file named #{file_name} is already in use by another document of item #{item.get_name}"
    end
  end

  # Adds a document to Sesame and updates the corresponding item in Solr
  def add_and_index_document(item, document_json_ld)
    add_and_index_document_in_sesame(item.id, document_json_ld)

    # Reindex item in Solr
    delete_item_from_solr(item.id)
    item.indexed_at = nil
    item.save
    update_item_in_solr(item)
  end

  #
  # Core functionality common to creating a collection
  #
  def create_collection_core(name, metadata, owner, licence_id=nil, private=true, text='')
    metadata = MetadataHelper::update_jsonld_collection_id(
      MetadataHelper::not_empty_collection_metadata!(name, current_user.full_name, metadata), name)
    uri = metadata['@id']
    # KL: if collection exist, update
    # if Collection.find_by_uri(uri).present? # ingest skips collections with non-unique uri
    #   raise ResponseError.new(400), "A collection with the name '#{name}' already exists"

    collection = Collection.find_by_uri(uri)
    unless collection.nil?
      # existing collection, update
      collection.name = name
      collection.uri = uri
      collection.owner = owner
      collection.licence_id = licence_id
      collection.private = private
      collection.text = text
      collection.save

      # MetadataHelper::update_collection_metadata_from_json(name, metadata)

      "Collection '#{name}' (#{uri}) updated"

    else
      if licence_id.present? and Licence.find_by_id(licence_id).nil?
        raise ResponseError.new(400), "Licence with id #{licence_id} does not exist"
      end

      MetadataHelper::create_manifest(name)

      MetadataHelper::update_collection_metadata_from_json(name, metadata)

      # corpus_dir = MetadataHelper::corpus_dir_by_name(name)

      # check_and_create_collection(name, corpus_dir, metadata)

      populate_triple_store(nil, name, nil)

      collection = Collection.find_by_name(name)

      collection.owner = owner

      collection.save

      "New collection '#{name}' (#{uri}) created"
    end
  end

  #
  # Core functionality common to add item ingest (via api and web app)
  # Returns a list of item identifiers corresponding to the items ingested
  #
  def add_item_core(collection, item_id_and_file_hash)
    ingest_items(collection.corpus_dir, item_id_and_file_hash)
  end

  #
  # Core functionality common to add document ingest (via api and web app)
  #
  def add_document_core(collection, item, document_metadata, document_filename)
    create_document(item, document_metadata)
    add_and_index_document(item, document_metadata)
    "Added the document #{File.basename(document_filename)} to item #{item.get_name} in collection #{collection.name}"
  end

  #
  # Validates that the given request parameters contains the required fields
  #
  def validate_required_web_fields(request_params, required_fields)
    required_fields.each do |key, value|
      raise ResponseError.new(400), "Required field '#{value}' is missing" if request_params[key].blank?
    end
  end

  #
  # Returns a validated hash of the collection additional metadata params
  #
  def validate_collection_additional_metadata(params)
    if params.has_key?(:additional_key) && params.has_key?(:additional_value)
      protected_collection_fields = [
        'dc:identifier',
        'dcterms:identifier',
        MetadataHelper::IDENTIFIER.to_s,
        'dc:title',
        'dcterms:title',
        MetadataHelper::TITLE.to_s,
        'dc:abstract',
        'dcterms:abstract',
        MetadataHelper::ABSTRACT.to_s,
        MetadataHelper::LOC_OWNER.to_s]

      validate_additional_metadata(params[:additional_key].zip(params[:additional_value]), protected_collection_fields)
    else
      {}
    end
  end

  #
  # Returns a validated hash of the item additional metadata params
  #
  def validate_item_additional_metadata(params)
    if params.has_key?(:additional_key) && params.has_key?(:additional_value)
      protected_item_fields = ['dc:identifier', 'dcterms:identifier', MetadataHelper::IDENTIFIER.to_s,
                                'dc:isPartOf', 'dcterms:isPartOf', MetadataHelper::IS_PART_OF.to_s]
      validate_additional_metadata(params[:additional_key].zip(params[:additional_value]), protected_item_fields)
    else
      {}
    end
  end

  #
  # Returns a validated hash of the document additional metadata params
  #
  def validate_document_additional_metadata(params)
    if params.has_key?(:additional_key) && params.has_key?(:additional_value)
      protected_item_fields = ['dc:identifier', 'dcterms:identifier', MetadataHelper::IDENTIFIER.to_s,
                                'dc:source', 'dcterms:source', MetadataHelper::SOURCE,
                                'olac:language', MetadataHelper::LANGUAGE.to_s]
      validate_additional_metadata(params[:additional_key].zip(params[:additional_value]), protected_item_fields)
    else
      {}
    end
  end

  #
  # Validates and sanitises a set of additional metadata provided by ingest web forms
  # Expects a zipped array of additional metadata keys and values, returns a hash of sanitised metadata
  #
  def validate_additional_metadata(additional_metadata, protected_field_keys, metadata_type="additional")
    default_protected_fields = ['@id', '@type', '@context',
                                'dc:identifier', 'dcterms:identifier', MetadataHelper::IDENTIFIER.to_s]
    metadata_protected_fields = default_protected_fields | protected_field_keys
    additional_metadata.delete_if {|key, value| key.blank? && value.blank?}
    metadata_hash = {}
    additional_metadata.each do |key, value|
      meta_key = key.delete(' ')
      meta_value = value.strip
      raise ResponseError.new(400), "An #{metadata_type} metadata field is missing a name" if meta_key.blank?
      raise ResponseError.new(400), "An #{metadata_type} metadata field '#{meta_key}' is missing a value" if meta_value.blank?

      unless metadata_protected_fields.include?(meta_key)
        # handle multi value
        if metadata_hash.key?(meta_key)
          #   key already exists
          v = metadata_hash[meta_key]
          if v.is_a? (Array)
            metadata_hash[meta_key] = (v << meta_value)
          else
            metadata_hash[meta_key] = (Array.new([v]) << meta_value)
          end
        else
          metadata_hash[meta_key] = meta_value
        end
      end
    end
    metadata_hash
  end

  # Validates OLAC metadata
  def validate_collection_olac_metadata(params)
    validate_additional_metadata(params[:collection_olac_name].zip(params[:collection_olac_value]), [], "OLAC")
  end

  #
  # Constructs Json-ld for a new item
  #
  def construct_item_json_ld(collection, item_name, item_title, metadata)
    item_metadata = {'@id' => Rails.application.routes.url_helpers.catalog_url(collection.name, item_name),
                      MetadataHelper::IDENTIFIER.to_s => item_name,
                      MetadataHelper::TITLE.to_s => item_title,
                      MetadataHelper::IS_PART_OF.to_s => {'@id' => collection.uri}
    }
    item_metadata.merge!(metadata) {|key, val1, val2| val1}
    {'@context' => JsonLdHelper::default_context, '@graph' => [item_metadata]}
  end

  #
  # Constructs Json-ld for a new document
  #
  def construct_document_json_ld(collection, item, language, document_file, metadata)
    JsonLdHelper::construct_document_json_ld(collection, item, language, document_file, metadata)
  end

  def zip_additional_metadata(meta_field_names, meta_field_values)
    if meta_field_names.nil? || meta_field_values.nil?
      []
    else
      meta_field_names.zip(meta_field_values)
    end
  end

  # Return default licence object.
  # If no licence retrieve according to input licence id, return default licence (Creative Commons v3.0 BY) instead
  def licence(licence_id)
    LicenceHelper.licence(licence_id)
  end

  #
  # Retrieve RDF name mapping
  #
  def metadata_names_mapping
    rlt = {}

    exclude_name = ['rdf:type']

    mappings = MetadataHelper::searchable_fields
    mappings.each do |m|
      unless exclude_name.include?(m.rdf_name)
        # rlt[m.rdf_name] = m.user_friendly_name.nil? ? m.rdf_name : m.user_friendly_name
        rlt[m.rdf_name] = m.rdf_name
      end
    end

    rlt
  end

  def merge_meta_arrays(meta_keys, meta_values, default_meta_keys, default_meta_values)
    # I imagine there's a more hipster way to do this
    # 
    merged = {}
    i = 0
    meta_keys.each do |k|
      merged[k] = meta_values[i]
      i = i + 1
    end

    i = 0
    default_meta_keys.each do |k|
      merged[k] = default_meta_values[i] unless merged.has_key?(k)
    end

    return merged
  end
end