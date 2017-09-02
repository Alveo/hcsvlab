require 'linkeddata'
require 'xmlsimple'
require "#{Rails.root}/app/helpers/blacklight/catalog_helper_behavior.rb"
require "#{Rails.root}/app/helpers/blacklight/blacklight_helper_behavior"
require "#{Rails.root}/lib/rdf-sesame/hcsvlab_server.rb"

Dir.glob("#{Rails.root}/lib/rdf/**/*.rb") {|f| require f}

#
# Solr_Worker
#
class Solr_Worker < ApplicationProcessor

  include Blacklight::CatalogHelperBehavior
  include Blacklight::BlacklightHelperBehavior
  include Blacklight::Configurable
  include Blacklight::SolrHelper

  #
  # =============================================================================
  # Configuration
  # =============================================================================
  #

  #
  # Load up the facet fields from the supplied config
  #
  def self.load_config
    @@configured_fields = Set.new
    FACETS_CONFIG[:facets].each do |aFacetConfig|
      @@configured_fields.add(aFacetConfig[:name])
    end
  end

  FACETS_CONFIG = YAML.load_file(Rails.root.join("config", "facets.yml")) unless const_defined?(:FACETS_CONFIG)
  SESAME_CONFIG = YAML.load_file("#{Rails.root.to_s}/config/sesame.yml")[Rails.env] unless const_defined?(:SESAME_CONFIG)
  STOMP_CONFIG = YAML.load_file("#{Rails.root.to_s}/config/broker.yml")[Rails.env] unless defined? STOMP_CONFIG

  load_config
  subscribes_to :solr_worker

  #
  # End of Configuration
  # -----------------------------------------------------------------------------
  #



  #
  # =============================================================================
  # Processing
  # =============================================================================
  #

  #
  # Deal with an incoming message
  #
  def on_message(message)
    # Expect message to be a json object containing at least a 'cmd' (command) verb
    
    info("Solr_Worker", "received: #{message}")

    packet = JSON.parse(message)    
    info("Solr_Worker", "packet: #{packet.inspect}")

    command = packet["cmd"]
    

    case command
      when "index"
        item_id = packet["arg"]
        begin
          index_item(item_id)
        rescue Exception => e
          error("Solr Worker", e.message)
          error("Solr Worker", e.backtrace)
          # Create when necessary rather than leaving an open connection for each worker
          stomp_client = Stomp::Client.open "#{STOMP_CONFIG['adapter']}://#{STOMP_CONFIG['host']}:#{STOMP_CONFIG['port']}"
          stomp_client.publish('alveo.solr.worker.dlq', message)
          stomp_client.close
        end

      when "delete"
        # TODO should we catch exceptions here?
        item_id = packet["arg"]
        delete(item_id)

      when "update_item_in_sesame"
        begin
          args = packet["arg"]
          update_item_in_sesame(args["new_metadata"], args["collection_id"])
        rescue Exception => e
          error("Solr Worker", e.message)
          error("Solr Worker", e.backtrace)
        end

      when "update_item_in_sesame_with_link"
        begin
          args = packet["arg"]
          update_item_in_sesame_with_link(args["item_id"], args["document_json_ld"])
        rescue Exception => e
          error("Solr Worker", e.message)
          error("Solr Worker", e.backtrace)
        end
      
      when "delete_item_from_sesame"
        begin
          args = packet["arg"]
          delete_item_from_sesame(item)
        rescue Exception => e
          error("Solr Worker", e.message)
          error("Solr Worker", e.backtrace)
        end
    else
      error("Solr_Worker", "unknown instruction: #{command}")
      return
    end

  end

private

  #
  # =============================================================================
  # Backgrounded Sesame routines
  # =============================================================================
  #

  def delete_item_from_sesame(item)
    repository = get_sesame_repository(item.collection)
    item.documents.each do |document|
      delete_document_from_sesame(document, repository)
    end
    issue_sesame_item_delete(item, repository)
  end

  #
  # Deletes statements from Sesame where the RDF subject matches the document URI
  #
  def delete_document_from_sesame(document, repository)
    document_uri = get_doc_subject_uri_from_sesame(document, repository)
    triples_with_doc_subject = RDF::Query.execute(repository) do
      pattern [document_uri, :predicate, :object]
    end
    triples_with_doc_subject.each do |statement|
      repository.delete(RDF::Statement(document_uri, statement[:predicate], statement[:object]))
    end
    triples_with_doc_object = RDF::Query.execute(repository) do
      pattern [:subject, :predicate, document_uri]
    end
    triples_with_doc_object.each do |statement|
      repository.delete(RDF::Statement(statement[:subject], statement[:predicate], document_uri))
    end
  end
  
  # Deletes statements with the item's URI from Sesame
  def issue_sesame_item_delete(item, repository)
    item_subject = RDF::URI.new(item.uri)
    item_query = RDF::Query.new do
      pattern [item_subject, :predicate, :object]
    end
    item_statements = repository.query(item_query)
    item_statements.each do |item_statement|
      repository.delete(RDF::Statement(item_subject, item_statement[:predicate], item_statement[:object]))
    end
  end

  def update_item_in_sesame(new_metadata, collection_id)
    collection = Collection.find(collection_id)
    repository = get_sesame_repository(collection)
    update_sesame_with_graph(new_metadata, repository)
  end

  def update_item_in_sesame_with_link(item_id, document_json_ld)
    logger.info "update_item_in_sesame_with_link: start - item_id[#{item_id}], document_json_ld[#{document_json_ld}]"

    item = Item.find(item_id)
    repository = get_sesame_repository(item.collection)

    # Upload doc rdf to Sesame
    document_RDF = RDF::Graph.new << JSON::LD::API.toRDF(document_json_ld)
    logger.debug "update_item_in_sesame_with_link: document_RDF[#{document_RDF.dump(:ttl)}]"

    update_sesame_with_graph(document_RDF, repository)

    # Add link in item rdf to doc rdf in sesame
    document_RDF_URI = RDF::URI.new(document_json_ld['@id'])
    item_document_link = {'@id' => item.uri, MetadataHelper::DOCUMENT.to_s => document_RDF_URI}
    append_item_graph = RDF::Graph.new << JSON::LD::API.toRDF(item_document_link)
    update_sesame_with_graph(append_item_graph, repository)
  end

  # Updates Sesame with the metadata graph
  # If statements already exist this updates the statement object rather than appending new statements
  def update_sesame_with_graph(graph, repository)
    start = Time.now

    graph.each_statement do |statement|
      if statement.predicate == MetadataHelper::DOCUMENT
        # An item can contain multiple document statements (same subj and pred, different obj)
        repository.insert(statement)
      else
        # All other statements should have unique subjects and predicates
        matches = RDF::Query.execute(repository) { pattern [statement.subject, statement.predicate, :object] }
        if matches.count == 0
          repository.insert(statement)
        else
          matches.each do |match|
            unless match[:object] == statement.object
              repository.delete([statement.subject, statement.predicate, match[:object]])
              repository.insert(statement)
            end
          end
        end
      end
    end

    endTime = Time.now
    logger.debug("Time for update_sesame_with_graph: (#{'%.1f' % ((endTime.to_f - start.to_f)*1000)}ms)")

    repository
  end

  #
  # =============================================================================
  # Indexing
  # =============================================================================
  #

  #
  # Do the indexing for an Item
  #
  def index_item(object)
    item = Item.find(object)
    collection = item.collection
    server = RDF::Sesame::HcsvlabServer.new(SESAME_CONFIG["url"].to_s)
    repository = server.repository(collection.name)
    raise Exception.new "Repository not found - #{collection.name}" if repository.nil?

    rdf_uri = RDF::URI.new(item.uri)
    basic_results = repository.query(:subject => rdf_uri)
    extras = {MetadataHelper::TYPE => [], MetadataHelper::EXTENT => [], "date_group_facet" => []}
    internal_use_data = {:documents_path => []}

    # Get date group if there is one
    date_result = repository.query(:subject => rdf_uri, :predicate => MetadataHelper::CREATED)
    unless date_result.empty?
      date = date_result.first_object
      group = date_group(date)
      extras["date_group_facet"] << group unless group.nil?
    end

    # get full text from item
    begin
      unless item.nil? || item.primary_text_path.nil?
        file = File.open(item.primary_text_path)
        full_text = file.read.encode('utf-8', invalid: :replace)
        file.close
      end 
    rescue
      warning("Solr_Worker", "caught exception fetching full_text for: #{object}")
      full_text = ""
    end
    # Get document info
    document_results = repository.query(:subject => rdf_uri, :predicate => RDF::URI.new(MetadataHelper::DOCUMENT))

    document_results.each { |result|
      document = result.to_hash[:object]

      doc_info = repository.query(:subject => document).to_hash[document]

      extras[MetadataHelper::TYPE] << doc_info[MetadataHelper::TYPE][0].to_s unless doc_info[MetadataHelper::TYPE].nil?

      extras[MetadataHelper::EXTENT] << doc_info[MetadataHelper::EXTENT][0].to_s unless doc_info[MetadataHelper::EXTENT].nil?

      internal_use_data[:documents_path] << doc_info[MetadataHelper::SOURCE][0].to_s unless doc_info[MetadataHelper::SOURCE].nil?
    }

    if store_results(object, basic_results, full_text, extras, internal_use_data, collection)
      item.indexed_at = Time.now
      item.save!
    end
  end

  #
  # Add a field to the solr document we're building. Knows about the
  # difference between dynamic and non-dynamic fields.
  #
  def add_field(result, field, value, binding)
    if @@configured_fields.include?(field)
      debug("Solr_Worker", "Adding configured field[#{field}] with value[#{value}]")
      ::Solrizer::Extractor.insert_solr_field_value(result, field, value)
    else
      debug("Solr_Worker", "Adding dynamic field[#{field}] with value[#{value}]")
      Solrizer.insert_field(result, field, value, :facetable, :stored_searchable)
    end

    process_field_mapping(field, binding)
  end

  #
  # Make a Solr document from information extracted from the Item
  #
  def make_solr_document(object, results, full_text, extras, internal_use_data, collection)
    logger.info "make_solr_document: start - object[#{object}], results[#{results}], full_text[#{full_text}], extras[#{extras}], internal_use_data[#{internal_use_data}], collection[#{collection}]"
    document = {}
    configured_fields_found = Set.new
    ident_parts = {collection: "Unknown Collection", identifier: "Unknown Identifier"}

    results.each { |result|

      result = result.to_hash
      # Set the defaults for field and value
      field = result[:predicate].to_s
      value = last_bit(result[:object])

      # Now check for special cases
      if result[:predicate] == MetadataHelper::CREATED
        value = result[:object].to_s
      elsif result[:predicate] == MetadataHelper::IS_PART_OF
        is_part_of = find_collection(result[:object])
        unless is_part_of.nil?
          # This is pointing at a collection, so treat it differently
          field = MetadataHelper::COLLECTION
          value = is_part_of.name
          ident_parts[:collection] = value
        end
      elsif result[:predicate] == MetadataHelper::IDENTIFIER
        ident_parts[:identifier] = value
      elsif @@configured_fields.include?(MetadataHelper::short_form(field)+"_facet")
        field = MetadataHelper::short_form(field)+"_facet"
      end

      # When retrieving the information for a document, the RDF::Query library is forcing
      # the text to be encoding to UTF-8, but that produces that some characters get misinterpreted,
      # so we need to correct that by re mapping the wrong characters in the right ones.
      # (maybe this is not the best solution :( )
      value_encoded = value.inspect[(1..-2)]
      replacements = []
      replacements << ['â\u0080\u0098', '‘']
      replacements << ['â\u0080\u0099', '’']
      replacements.each{ |set| value_encoded.gsub!(set[0], set[1]) }

      # Map the field name to it's short form
      field = MetadataHelper::short_form(field)
      configured_fields_found.add(field) if @@configured_fields.include?(field)
      add_field(document, field, value_encoded, result)

    }

    unless extras.nil?
      extras.keys.each { |key|
        field = MetadataHelper::short_form(key)
        values = extras[key]
        configured_fields_found.add(field) if @@configured_fields.include?(field) && (values.size > 0)
        values.each { |value|
          add_field(document, field, value, nil)

          # creates the field mapping
          uri = RDF::URI.new(key)
          rdf_field_name = (uri.qname.present?)? uri.qname.join(':') : nil
          solr_name = (@@configured_fields.include?(field)) ? field : "#{field}_tesim"

          # KL: To be compatible with existing SOLR field name,
          # DCTERMS => DC
          solr_name = solr_name.sub(/^DCTERMS_(.+)/, 'DC_\1')

          if ItemMetadataFieldNameMapping.create_or_update_field_mapping(solr_name, rdf_field_name, format_key(field))
            debug("Solr_Worker", "Creating new mapping for field #{field}")
          else
            debug("Solr_Worker", "Updating mapping for field: #{field}")
          end

        }
      }
    end
    unless full_text.nil?
      logger.debug "\tAdding configured field #{:full_text} with value #{trim(full_text, 128)}"
      ::Solrizer::Extractor.insert_solr_field_value(document, :full_text, full_text)
    end
    ident = ident_parts[:collection] + ":" + ident_parts[:identifier]
    #debug("Solr_Worker", "Adding configured field #{:id} with value #{object}")
    # ::Solrizer::Extractor.insert_solr_field_value(document, :id, object)
    ::Solrizer::Extractor.insert_solr_field_value(document, :id, ident)
    debug("Solr_Worker", "Adding configured field #{:handle} with value #{ident}")
    ::Solrizer::Extractor.insert_solr_field_value(document, :handle, ident)

    #Create group permission fields
    debug("Solr_Worker", "Adding discover Permission field for group with value #{ident_parts[:collection]}-discover")
    ::Solrizer::Extractor.insert_solr_field_value(document, :'discover_access_group_ssim', "#{ident_parts[:collection]}-discover")
    debug("Solr_Worker", "Adding read Permission field for group with value #{ident_parts[:collection]}-read")
    ::Solrizer::Extractor.insert_solr_field_value(document, :'read_access_group_ssim', "#{ident_parts[:collection]}-read")
    debug("Solr_Worker", "Adding edit Permission field for group with value #{ident_parts[:collection]}-edit")
    ::Solrizer::Extractor.insert_solr_field_value(document, :'edit_access_group_ssim', "#{ident_parts[:collection]}-edit")

    #Create user permission fields
    data_owner = collection.owner.email
    if data_owner
      debug("Solr_Worker", "Adding discover Permission field for user with value #{data_owner}-discover")
      ::Solrizer::Extractor.insert_solr_field_value(document, :'discover_access_person_ssim', "#{data_owner}")
      debug("Solr_Worker", "Adding read Permission field for user with value #{ident_parts[:collection]}-read")
      ::Solrizer::Extractor.insert_solr_field_value(document, :'read_access_person_ssim', "#{data_owner}")
      debug("Solr_Worker", "Adding edit Permission field for user with value #{ident_parts[:collection]}-edit")
      ::Solrizer::Extractor.insert_solr_field_value(document, :'edit_access_person_ssim', "#{data_owner}")
    end

    # Add in defaults for the configured fields we haven't found so far
    @@configured_fields.each { |field|
      add_field(document, field, "unspecified", nil) unless configured_fields_found.include?(field)
    }

    logger.info"make_solr_document: document[#{document}], internal_use_data[#{internal_use_data}]"
    add_json_metadata_field(object, document, internal_use_data)

    document
  end

  #
  #
  #
  def add_json_metadata_field(object, document, internal_use_data)
    logger.info "add_json_metadata_field: start - object[#{object}], document[#{document}], internal_use_data[#{internal_use_data}]"

    item_info = create_display_info_hash(document)
    # Removes id, item_list, *_ssim and *_sim fields
    #metadata = itemInfo.metadata.delete_if {|key, value| key.to_s.match(/^(.*_sim|.*_ssim|item_lists|id)$/)}
    metadata = item_info.metadata.delete_if { |key, value| key.to_s.match(/^(.*_sim|.*_ssim|id)$/) }

    # create a mapping with the documents locations {filename => fullPath}
    documents_locations = {}
    #documentsPath = Hash[*document.select{|key, value| key.to_s.match(/#{MetadataHelper.short_form(MetadataHelper::SOURCE.to_s)}_.*/)}.first]
    documents_path = internal_use_data[:documents_path]

    if documents_path.present?
      documents_path.each do |path|
        documents_locations[File.basename(path).to_s] = path.to_s
      end
    end
    item = Item.find(object)
    item.json_metadata = {catalog_url: item_info.catalog_url,
                          metadata: metadata,
                          primary_text_url: item_info.primary_text_url,
                          annotations_url: item_info.annotations_url,
                          documents: item_info.documents,
                          documentsLocations: documents_locations}.to_json.to_s
    item.save!
    # ::Solrizer::Extractor.insert_solr_field_value(document, 'json_metadata', json_metadata.to_s)

  end


  #---------------------------------------------------------------------------------------------------
  def process_field_mapping(field, binding)
    rdf_field_name = nil
    if binding.present? and binding[:predicate].qname.present?
      rdf_field_name = binding[:predicate].qname.join(':')
    elsif binding.present?
      debug("Solr_Worker", "WARNING: Vocab not defined for field #{field} (#{binding[:predicate].to_s}). Please update it in /lib/rdf/vocab.")
    end

    solr_name = @@configured_fields.include?(field) ? field : "#{field}_tesim"

    # KL: To be compatible with existing SOLR field name,
    # DCTERMS => DC
    solr_name = solr_name.sub(/^DCTERMS_(.+)/, 'DC_\1')

    if ItemMetadataFieldNameMapping.create_or_update_field_mapping(solr_name, rdf_field_name, format_key(field))
      debug("Solr_Worker", "Creating new mapping for field #{solr_name}")
    else
      debug("Solr_Worker", "Updating mapping for field: #{solr_name}")
    end

  end

  def format_key(uri)
    uri = last_bit(uri).sub(/_tesim$/, '')
    uri = uri.sub(/_facet/, '')
    uri = uri.sub(/^([A-Z]+_)+/, '') unless uri.starts_with?('RDF')

    uri
  end

  #---------------------------------------------------------------------------------------------------

  #
  # Make a Solr update document from information extracted from the Item
  #
  def make_solr_update(document)

    xml_update = "<add overwrite='true' allowDups='false'> <doc>"
      
    document.keys.each do | key |
    
      value = document[key]

      if key.to_s == "id"
        xml_update << "<field name='#{key.to_s}'>#{value.to_s}</field>"
      else
        if value.kind_of?(Array)
          value.each do |val| 
            xml_update << "<field name='#{key.to_s}' update='set'>#{CGI.escapeHTML(val.to_s.force_encoding('UTF-8'))}</field>"
          end
        else
          xml_update << "<field name='#{key.to_s}' update='set'>#{CGI.escapeHTML(value.to_s.force_encoding('UTF-8'))}</field>"
        end
      end
    end
    
    xml_update << "</doc> </add>"

    debug("Solr_Worker", "XML= " + xml_update)
    
    xml_update

  end

  #
  # Search for an object in Solr to see if we need to add or update
  #
  def object_exists_in_solr?(object)
    response = @@solr.get 'select', :params => { :q => object }
    (response['response']['docs'].count > 0) ? true : false
  end

  #
  # Update Solr with the information we've found
  #
  def store_results(object, results, full_text, extras = nil, internal_use_data, collection)
    logger.info "store_results: start - object[#{object}], results[#{results}], full_text[#{full_text}], extras[#{extras}], internal_use_data[#{internal_use_data}], collection[#{collection}]"

    get_solr_connection
    document = make_solr_document(object, results, full_text, extras, internal_use_data, collection)

    if document[:handle].eql?("Unknown Collection:Unknown Identifier")
      error("Solr_Worker", "Skipping " + object.to_s + " due to missing metadata")
      return false
    end

    if object_exists_in_solr?(object)
      info("Solr_Worker", "Updating " + object.to_s)
      xml_update = make_solr_update(document)
      response = @@solr.update :data => xml_update
      debug("Solr_Worker", "Update response= #{response.to_s}")
      response = @@solr.commit
      info("Solr_Worker", "Commit response= #{response.to_s}")
    else
      info("Solr_Worker", "Inserting " + object.to_s )
      response = @@solr.add(document)
      debug("Solr_Worker", "Add response= #{response.to_s}")
      response = @@solr.commit
      info("Solr_Worker", "Commit response= #{response.to_s}")
    end

    true
  end

  #
  # End of Indexing
  # -----------------------------------------------------------------------------
  #


  #
  # =============================================================================
  # Deleting
  # =============================================================================
  #

  #
  # Invoked when we get the "delete" command.
  #
  def delete(object)
    get_solr_connection
    @@solr.delete_by_id(object)
    @@solr.commit
  end

  #
  # End of Deleting
  # -----------------------------------------------------------------------------
  #


  #
  # =============================================================================
  # Solr
  # =============================================================================
  #

  #
  # Class variables for information about Solr
  @@solr_config = nil
  @@solr = nil

  #
  # Initialise the connection to Solr
  #
  def get_solr_connection
    if @@solr_config.nil?
      @@solr_config = Blacklight.solr_config
      @@solr        = RSolr.connect(@@solr_config)
    end
  end

  # Returns a collection repository from the Sesame server
  def get_sesame_repository(collection)
    server = RDF::Sesame::HcsvlabServer.new(SESAME_CONFIG["url"].to_s)
    server.repository(collection.name)
  end

  #
  # End of Solr
  # -----------------------------------------------------------------------------
  #



  #
  # =============================================================================
  # Date Handling
  # =============================================================================
  #
  def output(string)
    logger.debug(string)
  end

  def year_matching_regexp(string, regexp, match_idx)
    match = regexp.match(string)
    match = match[match_idx] unless match.nil?
    return match
  end

  def year_from_integer(y)
    y = y + 1900 if y < 100   # Y2K hack all over again?
    return y
  end


  #
  # Build a regular expression which looks for ^f1/f2/f3$ and records each element.
  # The separator doesn't have to be a /, any non-digit will do (but we insist on
  # the two separators being the same).
  #
  def make_regexp(f1, f2, f3)
    string = '^('
    string += f1
    string += ')(\D)('
    string += f2
    string += ')\2('
    string += f3
    string += ')$'
    return Regexp.new(string)
  end


  #
  # Try (quite laboriously) to get a year from the given date string.
  # Do this by matching against various regular expressions, which
  # correspond to various date formats.
  #
  def year_from_string(string)
    string = string.gsub('?', '') # Remove all doubt...
    day_p   = '1|2|3|4|5|6|7|8|9|01|02|03|04|05|06|07|08|09|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27|28|29|30|31'
    month_p = '1|2|3|4|5|6|7|8|9|01|02|03|04|05|06|07|08|09|10|11|12'
    year_p  = '[12]\d\d\d|\d\d'
    year ||= year_matching_regexp(string, make_regexp(day_p, month_p, year_p), 4)                 # 99/99/99 UK/Aus stylee
    year ||= year_matching_regexp(string, make_regexp(month_p, day_p, year_p), 4)                 # 99/99/99 US stylee
    year ||= year_matching_regexp(string, make_regexp(year_p, month_p, day_p), 1)                 # 99/99/99 Japan stylee

    year ||= year_matching_regexp(string, /^(\d+)$/, 1)                                           # 9999
    year ||= year_matching_regexp(string, /^\d+(\s)[[:alpha:]]+\1(\d+)/, 2)                       # 99 AAAAA 99
    year ||= year_matching_regexp(string, /^(\d{4})-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\+\d{4})?/, 1)  # ISO
    year ||= year_matching_regexp(string, /(\d+)$/, 1)  # Getting desperate, so look for digits at the end of the string
    unless year == nil
      year = year_from_integer(year.to_i)
    end
    return year
  end


  #
  # In order to handle the faceted search of date fields, we group them into
  # decades.
  #
  def date_group(field, resolution=10)
    #
    # Work out the date which field represents, whether it's a String or
    # an Integer or some other hideous mess.
    #
    c = field.class

    case
      when c == String
        year = year_from_string(field)
      when c == Fixnum
        year = year_from_integer(field)
      else
        year = year_from_string(field.to_s)
    end

    return "Unknown" if year.nil?

    #
    # Now work out the group into which it should fall and return a String
    # denoting that.
    #
    year /= resolution
    first = year * resolution
    last  = first + resolution - 1
    return "#{first} - #{last}"
  end

  #
  # End of Date Handling
  # -----------------------------------------------------------------------------
  #


  #
  # =============================================================================
  # Utility methods
  # =============================================================================
  #

  #
  # Look for a collection which the given URI might indicate. If we find one,
  # return it, otherwise return nil.
  #
  def find_collection(uri)
    uri = uri.to_s
    c = Collection.find_by_uri(uri)
    c = Collection.find_by_name(last_bit(uri)) if c.nil?
    c
  end


  #
  # Extract the last part of a path/URI/slash-separated-list-of-things
  #
  def last_bit(uri)
    str = uri.to_s                # just in case it is not a String object
    return str if str.match(/\s/) # If there are spaces, then it's not a path(?)
    return str.split('/')[-1]
  end


  #
  # Print out the results of an RDF query
  #
  def print_results(results, label)
    debug("Solr_Worker", "Results #{label}, with #{results.count} solutions(s)")
    results.each { |result|
      result.each_binding { |name, value|
        debug("Solr_Worker", "> #{name} -> #{value} (#{value.class})")
      }
    }
  end

  #
  # Trim a string to no more than the given number of characters
  #
  def trim(string, num)
    return string if string.length <= num
    return string[0, num-3] + "..."
  end

  #
  # End of Utility methods
  # -----------------------------------------------------------------------------
  #
end
