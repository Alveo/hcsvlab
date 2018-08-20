require 'find'
require "#{Rails.root}/lib/rdf-sesame/hcsvlab_server.rb"
require "#{Rails.root}/app/helpers/metadata_helper"
require "#{Rails.root}/app/helpers/collections_helper"
require 'csv'
require 'rest_client'

APP_CONFIG = YAML.load_file("#{Rails.root.to_s}/config/hcsvlab-web_config.yml")[Rails.env] unless defined? APP_CONFIG
SESAME_CONFIG = YAML.load_file("#{Rails.root.to_s}/config/sesame.yml")[Rails.env] unless defined? SESAME_CONFIG
STOMP_CONFIG = YAML.load_file("#{Rails.root.to_s}/config/broker.yml")[Rails.env] unless defined? STOMP_CONFIG
SESAME_SERVER = RDF::Sesame::HcsvlabServer.new(SESAME_CONFIG["url"].to_s)
METADATA_DIR = {
  "austalk" => "/mnt/volume/austalk/austalk-published/metadata"
}

VT_CONFIG = YAML.load_file("#{Rails.root.to_s}/config/voyant_tools.yml")[Rails.env] unless defined? VT_CONFIG

#
# Check collection integrity
#
# 1. Retrieve all/part item entries from DB according to specific collection, then handle items one by one;
# 2. Check item entry from Sesame, if all passed, go on; otherwise next;
#
def check_integrity(collection_name)
  start_time = Time.now

  collection = Collection.find_by_name(collection_name)
  if collection.nil?
    rlt = "collection with name '#{collection_name}' not found."

    return rlt
  end

  out_file = File.open(File.join(File.expand_path("~/tmp"), "#{collection_name}.handle"), "w")

  # retrieve total item count from db
  sql = "select count(*) from items where collection_id=#{collection.id}"
  total_items = ActiveRecord::Base.connection.execute(sql).as_json.first['count'].to_i

  # retrieve total doc count from db
  sql = "select count(*) from items i, documents d where i.id=d.item_id and i.collection_id=#{collection.id}"
  total_docs = ActiveRecord::Base.connection.execute(sql).as_json.first['count'].to_i

  puts "Found #{total_items} items with #{total_docs} documents in collection '#{collection_name}'"

  batch_size = 2000

  # test purpose
  # total_items = 2

  # retrieve item handle from DB
  (0..total_items - 1).step(batch_size).each do |i|
    items = Item.select("handle").where("collection_id = #{collection.id}").order("handle asc").limit(batch_size).offset(i)
    items.each_with_index do |item, index|
      progress = ((i + index + 1) * 1.0 / total_items) * 100
      printf "#{i + index + 1}/#{total_items} - processing #{item.handle} ... (%2.2f%%)\r", progress

      out_file << "#{item.handle}\n"
    end
  end

  out_file.close

  end_time = Time.now
  duration = (end_time - start_time) / 1.second
  msg = "Retrieving item handle finished at #{end_time} and last #{duration} seconds. Out file: #{File.absolute_path(out_file)}"
  puts msg

  return check_item(File.absolute_path(out_file))


end

def array_compare(array1, array2)
  rlt = false

  if array1.size != array2.size
    return rlt
  end

  array1.each do |a|
    a.gsub!("file://", "")
    if !array2.include?(a)
      return rlt
    end
  end

  rlt = true
  return rlt
end

def retrieve_doc_by_item_uri(repo, uri)
  rlt = []

  begin
    docs = repo.query(:subject => RDF::URI.new(uri), :predicate => RDF::URI.new(MetadataHelper::DOCUMENT))

    docs.each do |result|
      document = result.to_hash[:object]

      doc_info = repo.query(:subject => document).to_hash[document]

      path = doc_info[MetadataHelper::SOURCE][0].to_s unless doc_info[MetadataHelper::SOURCE].nil?

      rlt << path
    end
  rescue => e
    logger.error "retrieve_doc_by_item_uri: #{e.inspect}"
  end

  return rlt.sort
end

#
# Check item data integrity.
#
# file format:
# 1. one item handle per line. e.g.,
# austalk:4_882_2_5_007
# austalk:4_882_2_9_003
#
# Check procedure:
#
# 0. check item => document size
# 1. check item handle match document file name prefix
# 2. check document file exist
# 3. check DB document vs Sesame document (if failed check metadata file exist and complete)
def check_item(file_name)
  rlt = "done"
  out_file = open("#{file_name}.out", 'w')
  puts "Input file #{file_name} is ready"
  puts "Output file #{file_name}.out is ready"

  start_time = Time.now

  total_items = File.readlines(file_name).size
  total_err_items = 0

  repo = nil

  File.readlines(file_name).each_with_index do |line, index|
    handle = line.split("|").first.chomp
    collection_name = handle.split(":").first.to_s
    progress = ((index + 1) * 1.0 / total_items) * 100
    printf "#{index + 1}/#{total_items} - processing #{handle} ... (%2.2f%%)\r", progress
    item = Item.find_by_handle(handle)

    if item.nil?
      total_err_items += 1
      msg = "#{handle}| not found"
      out_file << "#{msg}\n"

      next
    end

    if item.documents.size == 0
      total_err_items += 1
      msg = "#{handle}|type-1| document not found."
      out_file << "#{msg}\n"

      next
    end

    is_item_err = false

    #   check item.documents
    db_docs = []

    item.documents.each do |doc|
      # validate db document file name
      if validate_doc_filename(handle, doc.file_path)
        if File.file?(doc.file_path)
          db_docs << doc.file_path
        else
          msg = "#{handle}|type-2| #{doc.file_path} not found"
          out_file << "#{msg}\n"

          is_item_err = true
        end
      else
        msg = "#{handle}|type-3| #{doc.file_path} filename invalid: inconsistent with handle"
        out_file << "#{msg}\n"

        is_item_err = true

      end
    end

    if is_item_err
      total_err_items += 1
      next
    end

    #   check sesame documents
    if repo.nil?
      repo = SESAME_SERVER.repository(collection_name)
    end

    sesame_docs = retrieve_doc_by_item_uri(repo, item.uri)
    is_ignore_item = false
    # validate sesame doc
    sesame_docs.each do |doc|
      if doc.starts_with?("/data/contrib/") || doc.starts_with?("file:///")
        #   mark as err, but not write to out_file
        is_ignore_item = true
        break
      end
    end

    if is_ignore_item
      msg = "#{handle}|type-4| sesame documents with wrong source, but still work, just ignore at this moment"
      out_file << "#{msg}\n"
      next
    end

    if array_compare(sesame_docs, db_docs)
      #   db vs sesame ok
    else
      msg = "#{handle}|type-5| documents #{db_docs} not match sesame documents #{sesame_docs}"
      total_err_items += 1
      # check metadata file to provide further info for investigation
      # assume each file has at least 6 entries of metadata, so from ch1 to ch6, at least 36 entries
      basic_metadata_entry_size = 6 * 6

      db_docs.each do |doc|
        if doc.include?("/audio/")
          #   check metadata file
          metadata_file = item_metadata_file(doc)
          if File.file?(metadata_file) && File.readlines(metadata_file).size >= basic_metadata_entry_size
            #   metadata file is OK
            msg += ", metadata file[#{metadata_file}] is ok"

            break
          else
            msg += ", #{doc} => #{metadata_file}, file not found or incomplete"
          end
        end
      end

      out_file << "#{msg}\n"
      next
    end

  end

  out_file.close
  end_time = Time.now
  duration = (end_time - start_time) / 1.second
  rlt = "Task finished at #{end_time} and last #{duration} seconds. Total error item(s): #{total_err_items}. Out file: #{file_name}.out"

  return rlt
end

#
# Fix inconsistent item.
#
# file format:
# 1. one item handle per line. e.g.,
# austalk:4_882_2_5_007
# austalk:4_882_2_9_003
def fix_item(file_name)
  rlt = "done"
  out_file = open("#{file_name}.out", 'w')
  start_time = Time.now

  total_items = File.readlines(file_name).size
  total_err_items = 0

  repo = nil

  File.readlines(file_name).each_with_index do |line, index|
    handle = line.split("|").first.chomp
    collection_name = handle.split(":").first.to_s
    progress = ((index + 1) * 1.0 / total_items) * 100
    printf "#{index + 1}/#{total_items} - processing #{handle} ... (%2.2f%%)\r", progress
    item = Item.find_by_handle(handle)

    if item.nil?
      total_err_items += 1
      msg = "#{handle}| not found"
      out_file << "#{msg}\n"
      next
    end

    #   check item.documents
    is_err_item = false
    doc_file_path = nil

    if item.documents.size == 0
      total_err_items += 1
      msg = "#{handle}| 0 document in DB"
      out_file << "#{msg}\n"

      is_err_item = true

      # don't go further
      next
    end

    item.documents.each do |doc|
      if File.file?(doc.file_path)
        if doc.file_path.include?("/audio/")
          # only use file within /audio/ as doc file, don't use downsampled file
          doc_file_path = doc.file_path
        end
      else
        msg = "#{handle}| #{doc.file_path} file not found"
        out_file << "#{msg}\n"

        is_err_item = true
      end
    end

    if is_err_item
      #   current item contains err doc, no further process
      total_err_items += 1
      next
    end

    metadata_file = item_metadata_file(doc_file_path)
    if !File.file?(metadata_file)
      msg = "#{handle}| #{doc_file_path} => #{metadata_file} not found\n"
      out_file << "#{msg}\n"

      is_err_item = true
    else
      #   ingest to sesame
      if repo.nil?
        repo = SESAME_SERVER.repository(collection_name)
      end

      begin
        repo.insert_from_rdf_files(metadata_file)
      rescue Exception => e
        msg = "#{handle}| ingest to sesame fail[#{e.message}]"
        out_file << "#{msg}\n"

        is_err_item = true
        next
      end
    end

    if is_err_item
      #   current item contains err doc, no further process
      total_err_items += 1
      next
    end

    #   update solr according to sesame

  end

  end_time = Time.now
  duration = (end_time - start_time) / 1.second
  rlt = "Task finished at #{end_time} and last #{duration} seconds. Total error item(s): #{total_err_items}. Out file: #{file_name}.out"

  return rlt
end

#
# Check missing speaker data (austalk). Generate CSV for further action.
#
def check_speaker_data(collection_name, file)
  rlt = "done"

  out_filename = File.join(File.dirname(file), "doc_not_found.csv")
  out_file = open("#{out_filename}", 'w')
  out_file << "university,source file path,item handle,document file path\n"

  ok_file_count = 0
  not_found_count = 0

  start_time = Time.now

  CSV.foreach(file, :headers => true) do |csv_line|
    univ = csv_line['University']
    folder = csv_line['Source Path']

    files = Dir.glob("#{folder}/**/*").select {|f| File.file? f}
    files.each do |f|

      item_handle = "#{collection_name}:" + extract_handle_from_filename(f)

      sql = %(
        select i.handle as item_handle, d.file_path as doc_path
        from collections c, items i, documents d
        where
          c.name='#{collection_name}'
          and i.collection_id=c.id
          and i.id=d.item_id
          and i.handle='#{item_handle}'
          and d.file_path='#{f}';
      )

      result = ActiveRecord::Base.connection.execute(sql)
      if result.count > 0
        ok_file_count += 1
      else

        logger.warn "file[#{f}] not found in DB.documents"

        # further check whether item exists

        sql = %(
          select i.handle
          from collections c, items i
          where
            c.name='#{collection_name}'
            and i.collection_id=c.id
            and i.handle='#{item_handle}';
        )

        result = ActiveRecord::Base.connection.execute(sql)
        if result.count == 0
          # item not exists
          item_handle = 'N/A'
        end

        doc_path = 'N/A'

        not_found_count += 1

        #   output
        puts "file[#{f}] not found, item[#{item_handle}]\n"
        out_file << "#{univ},#{f},#{item_handle},#{doc_path}\n"
      end

    end
  end

  out_file.close

  end_time = Time.now
  duration = (end_time - start_time) / 1.second

  rlt = "Task finished at #{end_time} and last #{duration} seconds. Total processed file(s): #{ok_file_count + not_found_count}, found [#{not_found_count}] file(s) not in DB.documents. Out file: #{out_filename}"

  return rlt

end

#
# Check item-doc consistency.
#
# Find all item(s) from DB which contain mis-match document(s).
#
# e.g.,
#
# (normal)
# item handle: austalk:1_1065_2_16_001
# documents: /mnt/volume/austalk/austalk-published/audio/CDUD/1_1065/2/sentences/1_1065_2_16_001-ch1-maptask.wav
#
# (abnormal)
# item handle: austalk:1_1065_2_16_001
# /mnt/volume/austalk/austalk-published/audio/CDUD/1_1065/2/sentences/other-handle-ch1-maptask.wav
#
# Input:
# - collection_name: collection name
# - handle_file(CSV): json file,handle,other?
#
# * if file_path nil, check whole collection
#
# Output:
# file - check result
# - handle,N/A: no such item in DB
# - handle,non-doc: item exists, but no related document in DB
# - handle,document name: item and document exist, but not match
#
def check_item_doc(collection_name, handle_file)
  rlt = "done"

  out_filename = File.join("/tmp", "#{collection_name}.err_handle.csv")
  out_file = open("#{out_filename}", 'w')

  total_handle = 0
  err_handle = 0
  start_time = Time.now

  total_line = %x{wc -l #{handle_file}}.split.first.to_i

  File.readlines(handle_file).each_with_index do |line, i|
    json_file = line.chop!.split(',').first
    handle = "#{collection_name}:#{line.split(',')[1]}"

    # check whether item exists
    sql = %(
      select handle from items where handle='#{handle}';
    )

    result = ActiveRecord::Base.connection.execute(sql)
    if result.count > 0
      #   good, item exists
      # further check item-doc

      sql = %(
        select i.handle, d.file_name
        from collections c, items i, documents d
        where
          c.name='#{collection_name}'
          and i.collection_id=c.id
          and i.id=d.item_id
          and i.handle='#{handle}';
      )

      result = ActiveRecord::Base.connection.execute(sql)
      if result.count > 0
        # check first record is good enough
        doc_file_name = result.as_json.first['file_name']
        if !doc_file_name.start_with?(handle.split(':').last)
          #   sorry, not match
          out_file << "#{json_file},#{handle},#{doc_file_name}\n"
          err_handle += 1
        end
      else
        #   no related doc exists
        out_file << "#{json_file},#{handle},non-doc\n"
        err_handle += 1
      end
    else
      # item not exist in DB
      out_file << "#{json_file},#{handle},N/A\n"
      err_handle += 1
    end

    total_handle += 1

    progress = ((i + 1) * 1.0 / total_line) * 100
    printf "#{i + 1}/#{total_line} - processing #{handle} ... (%2.2f%%)\r", progress
  end

  out_file.close

  end_time = Time.now
  duration = (end_time - start_time) / 1.second

  rlt = "Task finished at #{end_time} and last #{duration} seconds. Total processed handle(s): #{total_handle}, total error handle(s): #{err_handle}. Out file: #{out_filename}"

  return rlt
end

#
# Generate item handle file (handle per line) from meta-data file (json)
#
def gen_handle_file(collection_name, json_dir)
  rlt = "done"

  out_filename = File.join("/tmp", "#{collection_name}.handle.out")
  out_file = open("#{out_filename}", 'w')

  start_time = Time.now

  # recursively process all json file
  file_count = 0;
  handle_count = 0;
  Dir.glob("#{json_dir}/**/*.json").each do |json_file|
    handles = collect_handle_from_json(json_file)
    out_file.puts(handles)

    file_count += 1
    handle_count += handles.size
  end

  out_file.close

  end_time = Time.now
  duration = (end_time - start_time) / 1.second

  rlt = "Task finished at #{end_time} and last #{duration} seconds. Total processed file(s): #{file_count}, total handle(s): #{handle_count}. Out file: #{out_filename}"

  return rlt
end

#
# Collection handle from json
#
# JSONPath: $.items[*].alveo:metadata.dcterms:identifier
#
# Ref:
# - http://jsonpath.com/
# - http://goessner.net/articles/JsonPath/index.html
#
# Return: string array of item handle
#
def collect_handle_from_json(json_file)
  logger.debug "collect_handle_from_json: start - json_file[#{json_file}]"
  rlt = []

  begin
    json = JSON.parse(File.open(json_file).read.encode('utf-8'))

    json['items'].each {|item|
      if !item['alveo:metadata']['dcterms:identifier'].nil? && !item['alveo:metadata']['dcterms:identifier'].empty?
        rlt << "#{json_file},#{item['alveo:metadata']['dcterms:identifier']}"
      end
    }
  rescue Exception => e
    logger.error "collect_handle_from_json: #{e.message}"
  end

  logger.debug "collect_handle_from_json: end - rlt.size[#{rlt.size}]"

  return rlt
end

#
# Extract item handle from filename.
#
# - file basename split by '-', then take the first part.
# - if handle ends with non-number character, such as 'A', 'B',..., remove this character
#
# e.g.,
#
# /mnt/volume/austalk/austalk-published/audio/CDUD/1_1065/2/sentences/1_1065_2_16_001-ch1-maptask.wav => 1_1065_2_16_001
# /mnt/volume/austalk/austalk-published/audio/UNSW/1_532/1/story/1_532_1_3_001A-ch1-maptask.wav => 1_532_1_3_001
#
#
def extract_handle_from_filename(filename)
  rlt = nil

  begin
    rlt = filename.split('/').last.split('-').first

    if rlt.present? && !(rlt[-1].match(/[[:digit:]]/)).present?
      rlt = rlt[0..-2]
    end
  rescue Exception => e
    logger.error "extract_handle_from_filename: filename[${filename}] - #{e.message}"
  end

  return rlt

end

#
# Get metadata file for specific item's document file.
#
# So far only handle austalk collection.
#
# e.g.,
#
# doc file: /mnt/volume/austalk/austalk-published/audio/CDUD/4_421/3/words-3-2/4_421_3_33_242-ch1-maptask.wav
# metadata file: /mnt/volume/austalk/austalk-published/metadata/CDUD/4_421/3/words-3-2/4_421_3_33_242-files.nt
#
def item_metadata_file(doc_file)
  rlt = nil

  metadata_file_dir = METADATA_DIR["austalk"]
  doc_path = File.dirname(doc_file).to_s
  prefix = File.basename(doc_file).split("-").first.to_s

  begin
    # check whether last character is integer
    # occasionally prefix ends with 'A' to 'H'
    Integer(prefix[-1])
  rescue ArgumentError => e
    prefix = prefix[0..-2]
  end

  str = "/audio/"
  doc_path = doc_path.split(str).last.to_s

  rlt = metadata_file_dir + "/" + doc_path + "/" + prefix + "-files.nt"

  return rlt
end

# validate db document file name
#
# Document file name must match handle according to some rules.
#
# e.g., handle is austalk:xxx, file name must be:
#
# /mnt/volume/.../xxx-???.*
#
def validate_doc_filename(handle, doc)
  rlt = false

  prefix = "/" + handle.split(":").last.chomp

  if doc.include?(prefix)
    rlt = true
  end

  # logger.debug "handle[#{handle}], doc[#{doc}], rlt[#{rlt}]"

  return rlt

end

# -----------------------------------------

#
# Ingests a single item, creating both a collection object and manifest if they don't
# already exist.
#
def ingest_one(corpus_dir, rdf_file, user_email = nil)
  logger.debug "ingest_one: begin - corpus_dir[#{corpus_dir}], rdf_file[#{rdf_file}], user_email[#{user_email}]"
  collection_name = extract_manifest_collection(rdf_file)
  collection = check_and_create_collection(user_email, collection_name, corpus_dir, {}, File.basename(rdf_file))
  ingest_rdf_file(corpus_dir, rdf_file, true, collection)
end

def ingest_rdf_file(corpus_dir, rdf_file, annotations, collection)
  unless rdf_file.to_s =~ /metadata/ # HCSVLAB-441
    raise ArgumentError, "#{rdf_file} does not appear to be a metadata file - at least, its name doesn't say 'metadata'"
  end
  logger.info "Ingesting item: #{rdf_file}"

  filename, item_info = extract_manifest_info(rdf_file)
  item, update = create_item_from_file(corpus_dir, rdf_file, collection, item_info)

  server = RDF::Sesame::HcsvlabServer.new(SESAME_CONFIG["url"].to_s)
  repository = server.repository(collection.name)
  repository.insert_from_rdf_files(rdf_file)

  if update
    look_for_annotations(item, rdf_file) if annotations
    look_for_documents(item, corpus_dir, rdf_file, item_info)

    item.save!
  end

  item.id
end

def create_item_from_file(corpus_dir, rdf_file, collection, item_info)
  identifier = item_info["id"]
  uri = item_info["uri"]

  # collection_name = manifest["collection_name"]
  handle = "#{collection.name}:#{identifier}"

  existing_item = Item.find_by_handle(handle)

  if existing_item.present? && File.mtime(rdf_file).utc < existing_item.updated_at.utc
    logger.info "Item = #{existing_item.id} already up to date"
    return existing_item, false
  else
    if existing_item
      item = existing_item
    else
      item = Item.new
    end

    item.handle = handle
    item.uri = uri
    item.collection = collection
    item.save!

    unless Rails.env.test?
      stomp_client = Stomp::Client.open "#{STOMP_CONFIG['adapter']}://#{STOMP_CONFIG['host']}:#{STOMP_CONFIG['port']}"
      reindex_item_to_solr(item.id, stomp_client)
      stomp_client.close
    end

    if existing_item
      logger.info "Item = #{existing_item.id} updated"
    else
      logger.info "Item = #{item.id} created"
    end
    return item, true
  end
end

def add_and_index_document_in_sesame(item_id, document_json_ld)
  logger.info "add_and_index_document_in_sesame: start - item_id[#{item_id}], document_json_ld[#{document_json_ld}]"

  unless Rails.env.test?

    stomp_client = Stomp::Client.open "#{STOMP_CONFIG['adapter']}://#{STOMP_CONFIG['host']}:#{STOMP_CONFIG['port']}"
    packet = {
      :cmd => "update_item_in_sesame_with_link",
      :arg => {
        :item_id => item_id,
        :document_json_ld => document_json_ld
      }
    }
    stomp_client.publish('alveo.solr.worker', packet.to_json)
    stomp_client.close
  end
end

# stomp_client is passed in because this method may be called repeatedly on one connection
# e.g. rake tasks
def reindex_item_to_solr(item_id, stomp_client)
  logger.info "Reindexing item: #{item_id}"
  packet = {:cmd => "index", :arg => item_id}
  stomp_client.publish('alveo.solr.worker', packet.to_json)
end

def delete_item_from_solr(item_id)
  delete_object_from_solr(item_id)
end

def delete_document_from_solr(document_id)
  delete_object_from_solr(document_id)
end

def delete_object_from_solr(object_id)
  logger.info "Deindexing item: #{object_id}"
  #ToDo: refactor this workaround into a proper test mock/stub
  if Rails.env.test?
    json = {:cmd => "delete", :arg => "#{object_id}"}
    Solr_Worker.new.on_message(JSON.generate(json).to_s)
  else
    stomp_client = Stomp::Client.open "#{STOMP_CONFIG['adapter']}://#{STOMP_CONFIG['host']}:#{STOMP_CONFIG['port']}"
    packet = {:cmd => "delete", :arg => object_id}
    stomp_client.publish('alveo.solr.worker', packet.to_json)
    stomp_client.close
  end
end

def check_and_create_collection(user_email, collection_name, corpus_dir, json_metadata = {}, glob = "*-{metadata,ann}.rdf")

  # KL
  # if collection_name == "ice" && File.basename(corpus_dir)!="ice" #ice has different directory structure
  #   dir = File.expand_path("../../..", corpus_dir)
  # else
  #   dir = File.expand_path("..", corpus_dir)
  # end
  #
  # # KL: replace .n3 file with db
  # if Dir.entries(dir).include?(collection_name + ".n3")
  #   coll_metadata = dir + "/" + collection_name + ".n3"
  # else
  #   raise ArgumentError, "No collection metadata file found - #{dir}/#{collection_name}.n3. Stopping ingest."
  # end

  collection = Collection.find_by_name(collection_name)

  # Tip: if the collection doesn't exist, it's created by
  # update_rdf_graph via update_collection_metadata_from_json
  # 
  is_new = false
  if collection.nil?
    is_new = true
    logger.info "Creating collection #{collection_name}"
    # create_collection_from_file(coll_metadata, collection_name)
    json_metadata = MetadataHelper::update_jsonld_collection_id(json_metadata, collection_name)
    collection = MetadataHelper::update_collection_metadata_from_json(collection_name, json_metadata)

    # collection = Collection.find_by_name(collection_name)

    # set collection owner
    user_email ||= APP_CONFIG['default_data_owner']
    collection.owner = User.find_by_email(user_email)
  else
    # Update RDF file path but don't save yet.
    # KL
    # collection.rdf_file_path = coll_metadata
  end

  # paradisec_collection_setup(collection, is_new)
  populate_triple_store(corpus_dir, collection_name, glob)

  collection.save
  collection
end


def paradisec_collection_setup(collection, is_new)
  collection_name = collection.name
  if collection_name[/^paradisec-/]
    if is_new
      # Default to Nick Thieberger
      data_owner = User.find_by_email('thien@unimelb.edu.au')
      data_owner = find_default_owner if data_owner.nil?

      # Create PARADISEC list automatically
      collection_list = CollectionList.find_or_initialize_by_name('PARADISEC')
      if collection_list.new_record?
        collection_list.owner = data_owner
        collection_list.private = true
        collection_list.licence = Licence.find_by_name('PARADISEC Conditions of Access')
        collection_list.save
      end

      collection.owner = data_owner
      collection.save
      collection_list.add_collections([collection.id])
    end

    graph = collection.rdf_graph
    query = RDF::Query.new({collection: {MetadataHelper::RIGHTS => :rights}})

    results = query.execute(graph)
    if results.present? and results[0][:rights].to_s[/Open/].blank?
      clear_collection_metadata(collection_name) # just in case
      raise ArgumentError, "Collection #{collection_name} (#{collection.uri}) is not an Open collection - skipping"
    end
  end

end

def create_collection_from_file(collection_file, collection_name)
  coll = Collection.new
  coll.name = collection_name

  coll.rdf_file_path = collection_file
  graph = coll.rdf_graph
  coll.uri = graph.statements.first.subject.to_s


  if Collection.find_by_uri(coll.uri).present?
    # There is already such a collection in the system
    logger.error "Collection #{collection_name} (#{coll.uri}) already exists in the system - skipping"
    return
  end
  set_data_owner(coll)

  coll.save!

  logger.info "Collection '#{coll.name}' Metadata = #{coll.id}" unless Rails.env.test?
end

def look_for_documents(item, corpus_dir, rdf_file, item_info)
  start = Time.now

  # Create a primary text in the Item for primary text documents
  begin
    server = RDF::Sesame::HcsvlabServer.new(SESAME_CONFIG["url"].to_s)
    repository = server.repository(item.collection.name)

    query = RDF::Query.new do
      pattern [RDF::URI.new(item.uri), MetadataHelper::INDEXABLE_DOCUMENT, :indexable_doc]
      pattern [:indexable_doc, MetadataHelper::SOURCE, :source]
    end

    results = repository.query(query)

    results.each do |res|
      path = URI(res[:source]).path
      if File.exists? path and File.file? path
        item.primary_text_path = path
        item.save
      end
    end
  rescue => e
    Rails.logger.error e.inspect
    Rails.logger.error "Could not connect to triplestore - #{SESAME_CONFIG["url"].to_s}"
  end

  item_info["docs"].each do |result|
    identifier = result["identifier"]
    source = result["source"]
    path = URI.decode(URI(source).path)
    type = result["type"]

    file_name = last_bit(source)
    doc = item.documents.find_or_initialize_by_file_name(file_name)
    if doc.new_record?
      begin
        doc.file_path = path
        doc.doc_type = type
        doc.mime_type = mime_type_lookup(file_name)
        doc.item = item
        doc.item_id = item.id

        doc.save

        logger.info "#{type} Document = #{doc.id.to_s}" unless Rails.env.test?
      rescue Exception => e
        logger.error("Error creating document: #{e.message}")
      end
    else
      update_document(doc, item, file_name, identifier, source, type, corpus_dir)
    end
  end

  endTime = Time.now
  logger.debug("Time for look_for_documents: (#{'%.1f' % ((endTime.to_f - start.to_f) * 1000)}ms)")
end

def update_document(document, item, file_name, identifier, source, type, corpus_dir)
  begin
    path = URI.decode(URI(source).path)

    document.file_name = file_name
    document.file_path = path
    document.doc_type = type
    document.mime_type = mime_type_lookup(file_name)
    document.item = item
    document.save

    logger.info "Path:" + path
    if File.exists? path and File.file? path and STORE_DOCUMENT_TYPES.include? type
      case type
        when 'Text'
          item.primary_text_path = path
          item.save
        else
          logger.warn "??? Creating a #{type} document for #{path} but not adding it to its Item" unless Rails.env.test?
      end
    end
    logger.info "#{type} Document = #{document.id.to_s}" unless Rails.env.test?
  rescue Exception => e
    logger.error("Error creating document: #{e.message}")
  end
end

def look_for_annotations(item, metadata_filename)
  annotation_filename = metadata_filename.sub("metadata", "ann")
  return if annotation_filename == metadata_filename # HCSVLAB-441

  #TODO could be removed once we completely rely on the triple store?
  if File.exists?(annotation_filename)
    if item.annotation_path.blank?
      item.annotation_path = annotation_filename
      logger.info "Annotation datastream added for #{File.basename(annotation_filename)}" unless Rails.env.test?
    else
      item.annotation_path = annotation_filename
      logger.info "Annotation datastream updated for #{File.basename(annotation_filename)}" unless Rails.env.test?
    end
  end
end

#
# Find and set the data owner for the given collection
#
def set_data_owner(collection)

  # See if there is a responsible person specified in the collection's metadata
  query = RDF::Query.new({collection: {MetadataHelper::LOC_RESPONSIBLE_PERSON => :person}})

  results = query.execute(collection.rdf_graph)
  data_owner = find_system_user(results)
  data_owner = find_default_owner if data_owner.nil?
  if data_owner.nil?
    logger.warn "Cannot determine data owner for collection #{collection.name}"
  elsif data_owner.cannot_own_data?
    logger.warn "Proposed data owner #{data_owner.email} does not have appropriate permission - ignoring"
  else
    logger.info "Setting data owner to #{data_owner.email}"
    collection.owner = data_owner
  end
end

#
# Create collection manifest if one doesn't already exist
# Deprecated: old ingest route. TODO update tests
def check_and_create_manifest(corpus_dir)
  if !File.exists? File.join(corpus_dir, MANIFEST_FILE_NAME)
    create_collection_manifest(corpus_dir)
  end
end

#
# Create the collection manifest file for a directory
#
def create_collection_manifest(corpus_dir)
  logger.info("Creating collection manifest for #{corpus_dir}")
  overall_start = Time.now

  failures = []
  rdf_files = Dir.glob(corpus_dir + '/*-metadata.rdf')

  manifest_hash = {"collection_name" => extract_manifest_collection(rdf_files.first), "files" => {}}

  rdf_files.each do |rdf_file|
    filename, manifest_entry = extract_manifest_info(rdf_file)
    manifest_hash["files"][filename] = manifest_entry
    if !manifest_entry["error"].nil?
      failures << filename
    end
  end

  begin
    file = File.open(File.join(corpus_dir, MANIFEST_FILE_NAME), "w")
    file.puts(manifest_hash.to_json)
  ensure
    file.close if !file.nil?
  end

  endTime = Time.now
  logger.debug("Time for creating manifest for #{corpus_dir}: (#{'%.1f' % ((endTime.to_f - overall_start.to_f) * 1000)}ms)")
  logger.debug("Failures: #{failures.to_s}") if failures.size > 0
end

#
# query the given rdf file to find the collection name
#
def extract_manifest_collection(rdf_file)
  extract_start = Time.now

  graph = RDF::Graph.load(rdf_file, :format => :ttl, :validate => true)
  query = RDF::Query.new({
                           :item => {
                             RDF::URI(MetadataHelper::IS_PART_OF) => :collection
                           }
                         })
  result = query.execute(graph)[0]
  collection_name = last_bit(result.collection.to_s)
  # small hack to handle austalk for the time being, can be fixed up
  # when we look at getting some form of data uniformity
  if query.execute(graph).any? {|r| r.collection == "http://ns.austalk.edu.au/corpus"}
    collection_name = "austalk"
  end

  endTime = Time.now
  logger.debug("Time to extract info from #{rdf_file} (#{'%.1f' % ((endTime.to_f - extract_start.to_f) * 1000)}ms)")

  collection_name
end

#
# query the given rdf file to produce a hash item to add to the manifest
#
def extract_manifest_info(rdf_file)
  filename = File.basename(rdf_file)
  begin
    graph = RDF::Graph.load(rdf_file, :format => :ttl, :validate => true)
    query = RDF::Query.new({
                             :item => {
                               RDF::URI("http://purl.org/dc/terms/identifier") => :identifier
                             }
                           })
    result = query.execute(graph)[0]
    identifier = result.identifier.to_s
    uri = result[:item].to_s

    hash = {"id" => identifier, "uri" => uri, "docs" => []}

    query = RDF::Query.new({
                             :document => {
                               RDF::URI("http://purl.org/dc/terms/type") => :type,
                               RDF::URI("http://purl.org/dc/terms/identifier") => :identifier,
                               RDF::URI("http://purl.org/dc/terms/source") => :source
                             }
                           })
    query.execute(graph).each do |result|
      hash["docs"].append({"identifier" => result.identifier.to_s, "source" => result.source.to_s, "type" => result.type.to_s})
    end
  rescue => e
    logger.error "Error! #{e.message}"
    return filename, {"error" => "parse-error"}
  end

  return filename, hash
end

def check_corpus(corpus_dir)

  puts "Checking #{corpus_dir}..."

  rdf_files = Dir.glob(corpus_dir + '/*-metadata.rdf')

  errors = {}
  handles = {}

  index = 0

  rdf_files.each do |rdf_file|
    begin
      index = index + 1
      handle = check_rdf_file(rdf_file, index, rdf_files.size)
      handles[handle] = Set.new unless handles.has_key?(handle)
      handles[handle].add(rdf_file)
      if handles[handle].size > 1
        puts "Duplicate handle #{handle} found in:"
        handles[handle].each {|filename|
          puts "\t#{filename}"
        }
      end
    rescue => e
      logger.error "File: #{rdf_file}: #{e.message}"
      errors[rdf_file] = e.message
    end
  end

  handles.keep_if {|key, value| value.size > 1}
  report_check_results(rdf_files.size, corpus_dir, errors, handles)
end


def check_rdf_file(rdf_file, index, limit)
  unless rdf_file.to_s =~ /metadata/ # HCSVLAB-441
    raise ArgumentError, "#{rdf_file} does not appear to be a metadata file - at least, it's name doesn't say 'metadata'"
  end
  logger.info "Checking file #{index} of #{limit}: #{rdf_file}"
  graph = RDF::Graph.load(rdf_file, :format => :ttl, :validate => true)
  query = RDF::Query.new({
                           :item => {
                             RDF::URI(MetadataHelper::IS_PART_OF) => :collection,
                             RDF::URI(MetadataHelper::IDENTIFIER) => :identifier
                           }
                         })
  result = query.execute(graph)[0]
  identifier = result.identifier.to_s
  collection_name = last_bit(result.collection.to_s)

  # small hack to handle austalk for the time being, can be fixed up
  # when we look at getting some form of data uniformity
  if query.execute(graph).any? {|r| r.collection == "http://ns.austalk.edu.au/corpus"}
    collection_name = "austalk"
  end

  handle = "#{collection_name}:#{identifier}"
  logger.info "Handle is #{handle}"
  return handle
end


def report_results(label, corpus_dir, successes, errors)
  begin
    logfile = "log/ingest_#{File.basename(corpus_dir)}.log"
    logstream = File.open(logfile, "w")

    message = "Successfully ingested #{successes.size} Item#{successes.size == 1 ? '' : 's'}"
    message += ", and rejected #{errors.size} Item#{errors.size == 1 ? '' : 's'}" unless errors.empty?
    logger.info message
    logger.info "Writing summary to #{logfile}"

    logstream << "#{label}" << "\n\n"
    logstream << message << "\n"

    unless successes.empty?
      logstream << "\n"
      logstream << "Successfully Ingested" << "\n"
      logstream << "=====================" << "\n"
      successes.each {|item, message|
        logstream << "Item #{item} as #{message}" << "\n"
      }
    end

    unless errors.empty?
      logstream << "\n"
      logstream << "Error Summary" << "\n"
      logstream << "=============" << "\n"
      errors.each {|item, message|
        logstream << "\nItem #{item}:" << "\n\n"
        logstream << "#{message}" << "\n"
      }

      puts "Error ingesting #{File.basename(corpus_dir)} collection. See #{logfile} for details."
    end
  ensure
    logstream.close if !logstream.nil?
  end
end

def report_check_results(size, corpus_dir, errors, handles)
  begin
    logfile = "log/check_#{File.basename(corpus_dir)}.log"
    logstream = File.open(logfile, "w")

    message = "Checked #{size} metadata file#{size == 1 ? '' : 's'}"
    message += ", finding #{errors.size} syntax error#{errors.size == 1 ? '' : 's'}"
    message += ", and #{handles.size} duplicate handle#{handles.size == 1 ? '' : 's'}"
    logger.info message
    logger.info "Writing summary to #{logfile}"

    logstream << "Checking #{corpus_dir}" << "\n\n"
    logstream << message << "\n"

    unless errors.empty?
      logstream << "\n"
      logstream << "Error Summary" << "\n"
      logstream << "=============" << "\n"
      errors.each {|item, message|
        logstream << "\nItem #{item}:" << "\n\n"
        logstream << "#{message}" << "\n"
      }
    end

    unless handles.empty?
      logstream << "\n"
      logstream << "Duplicate Handles" << "\n"
      logstream << "=================" << "\n"
      handles.each {|handle, list|
        logstream << "\nHandle #{handle}:" << "\n"
        list.each {|filename|
          logstream << "\t#{filename}" << "\n"
        }
      }
    end
  ensure
    logstream.close
  end
end

def parse_boolean(string, default = false)
  return default if string.blank? # nil.blank? returns true, so this is also a nil guard.
  return false if string =~ (/(false|f|no|n|0)$/i)
  return true if string =~ (/(true|t|yes|y|1)$/i)
  raise ArgumentError.new("invalid value for Boolean: \"#{string}\", should be \"true\" or \"false\"")
end

def find_corpus_items(corpus)
  response = @solr.get 'select', :params => {:q => 'collection_name_facet:' + corpus,
                                             :rows => 2147483647}
  response['response']['docs']
end

def setup_collection_list(list_name, licence, *collection_names)
  list = CollectionList.create_public_list(list_name, licence, *collection_names)
  logger.warn("Didn't create CollectionList #{list_name}") if list.nil?
end

# Appears to be unused
# 
# def send_solr_message(command, objectID)
#   info("Fedora_Worker", "sending instruction to Solr_Worker: #{command} #{objectID}")
#   publish :solr_worker, "#{command} #{objectID}"
#   debug("Fedora_Worker", "Cache size: #{@@cache.size}")
#   @@cache.each_pair { |key, value|
#     debug("Fedora_Worker", "   @cache[#{key}] = #{value}")
#   }
# end

#
# Store all metadata and annotations from the given directory in the triplestore
#
def clear_collection_metadata(collection_name)
  logger.info "Start clearing #{collection_name}"

  # clear Solr
  uri = URI.parse(Blacklight.solr_config[:url] + '/update?commit=true')

  req = Net::HTTP::Post.new(uri)
  req.body = "<delete><query>collection_name_facet:#{collection_name}</query></delete>"

  req.content_type = "text/xml; charset=utf-8"
  req.body.force_encoding("UTF-8")
  res = Net::HTTP.start(uri.hostname, uri.port) do |http|
    http.request(req)
  end

  # Clear all metadata and annotations from the triple store
  server = RDF::Sesame::HcsvlabServer.new(SESAME_CONFIG["url"].to_s)
  repository = server.repository(collection_name)
  repository.clear if repository.present?

  # Now will store every RDF file
  logger.info "Finished clearing #{collection_name}"
end

#
# Store all metadata and annotations from the given directory in the triplestore
#
def populate_triple_store(corpus_dir, collection_name, glob)
  logger.info "Start ingesting files matching #{glob} in #{corpus_dir}"
  start = Time.now

  server = RDF::Sesame::HcsvlabServer.new(SESAME_CONFIG["url"].to_s)

  # First we will create the repository for the collection, in case it does not exists
  # This returns false if the repo already exists (costs about 4ms)
  server.create_repository(RDF::Sesame::HcsvlabServer::NATIVE_STORE_TYPE, collection_name, "Metadata and Annotations for #{collection_name} collection")

  # Create a instance of the repository where we are going to store the metadata
  repository = server.repository(collection_name)

  # TODO: add metadata to sesame

  # KL - deprecated features
  # Now will store every RDF file
  # if !corpus_dir.nil? && !glob.nil?
  #   repository.insert_from_rdf_files("#{corpus_dir}/**/#{glob}")
  # end

  endTime = Time.now
  logger.debug("Time for populate_triple_store: (#{'%.1f' % ((endTime.to_f - start.to_f) * 1000)}ms)")

  logger.info "Finished ingesting files matching #{glob} in #{corpus_dir}"
end

#
# Given an RDF query result set, find the first system user corresponding to a :person
# in that result set. Or nil, should there be no such user/an empty result set.
#
def find_system_user(results)
  results.each {|result|
    next unless result.has_variables?([:person])
    q = result[:person].to_s
    u = User.find_by_email(q)
    return u if u
  }
  nil
end


#
# Find the default data owner
#
def find_default_owner
  logger.debug "looking for default_data_owner in the APP_CONFIG, e-mail is #{APP_CONFIG['default_data_owner']}"
  email = APP_CONFIG["default_data_owner"]
  User.find_by_email(email)
end


#
# Ingest default set of licences
#
def create_default_licences(root_path = "config")
  Rails.root.join(root_path, "licences").children.each do |lic|
    lic_info = YAML.load_file(lic)

    begin
      l = Licence.new
      l.name = lic_info['name']
      l.text = lic_info['text']
      l.private = false

      l.save!
    rescue Exception => e
      logger.error "Licence Name: #{l.name} not ingested: #{l.errors.messages.inspect}"
      next
    else
      logger.info "Licence '#{l.name}' = #{l.id}" unless Rails.env.test?
    end

  end
end


#
# Extract the last part of a path/URI/slash-separated-list-of-things
#
def last_bit(uri)
  str = uri.to_s # just in case it is not a String object
  return str if str.match(/\s/) # If there are spaces, then it's not a path(?)
  return str.split('/')[-1]
end

#
# Rough guess at mime_type from file extension
#
def mime_type_lookup(file_name)
  case File.extname(file_name.to_s)

    # Text things
    when '.txt'
      return 'text/plain'
    when '.xml'
      return 'text/xml'

    # Images
    when '.jpg'
      return 'image/jpeg'
    when '.tif'
      return 'image/tif'

    # Audio things
    when '.mp3'
      return 'audio/mpeg'
    when '.wav'
      return 'audio/wav'

    # Video things
    when '.avi'
      return 'video/x-msvideo'
    when '.mov'
      return 'video/quicktime'
    when '.mp4'
      return 'video/mp4'

    # Other stuff
    when '.doc'
      return 'application/msword'
    when '.pdf'
      return 'application/pdf'

    # Default
    else
      return 'application/octet-stream'
  end
end

#
# Export collection documents according to pattern into zip file
#
# return: {:code => int, :message => string}
# - rlt[:code]: 0 if success, otherwise failure
# - rlt[:message]: nil if success, otherwise error message
def export_collection_doc(collection_name, zip_file, pattern)
  logger.debug "export_collection_doc: start - collection_name[#{collection_name}], pattern[#{pattern}], zip_file[#{zip_file}]"

  rlt = {:code => 1, :message => "unknown error"}

  # verify collection
  collection = Collection.find_by_name(collection_name)
  if !collection.present?
    rlt[:message] = "collection '#{collection_name}' not found"
  else
    # collect document file path according to pattern
    begin
      file_path_ar = CollectionsHelper.filter_doc(collection_name, pattern, false)

      if file_path_ar.count > 0
        # ensure no duplicated zip
        File.delete(zip_file) if File.exists?(zip_file)

        # zip it
        ZipBuilder.build_simple_zip_from_files(zip_file, file_path_ar)

        rlt[:code] = 0
        rlt[:message] = nil
      else
        #     no doc found according to current pattern
        rlt[:message] = "no document found according to pattern '#{pattern}'"
      end
    rescue Exception => e
      rlt[:message] = e.message
    end
  end

  logger.debug "export_collection_doc: end - rlt[#{rlt}]"

  return rlt

end

#
# Import collection document to voyant-tools
#
# Return:
# - rlt[:code]: 0 - success, 1 - failure
# - rlt[:message]: Voyant-Tools url if success, otherwise json response from voyant-tools
#
def import_vt(collection_name, file)
  logger.debug "import_vt: start - collection_name[#{collection_name}], file[#{file}]"
  rlt = {:code => 1, :message => "unknown error"}

  upload_url = VT_CONFIG["upload_url"]

  resp = RestClient.post(
    upload_url,
    :tool => 'corpus.CorpusCreator',
    :upload => File.open(file, 'r')
  )

  resp_json = JSON.parse(resp.body)

  if resp.code == 200 && resp_json['stepEnabledCorpusCreator']['storedId'].present?
    rlt[:code] = 0
    rlt[:message] = VT_CONFIG["url"] + resp_json['stepEnabledCorpusCreator']['storedId']
  else
    rlt[:message] = resp_json
  end

  logger.debug "import_vt: rlt[#{rlt}]"

  return rlt
end