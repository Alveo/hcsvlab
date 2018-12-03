require Rails.root.join('lib/rdf-sesame/hcsvlab_server.rb')
require Rails.root.join('app/helpers/collections_helper.rb')
require Rails.root.join('lib/item/download_items_helper')
require 'zip'
require 'mimemagic'

module ContributionsHelper

  SESAME_CONFIG = YAML.load_file("#{Rails.root.to_s}/config/sesame.yml")[Rails.env] unless defined? SESAME_CONFIG

  # Load contribution's metadata, return json
  #
  #
  def self.load_contribution_metadata(contribution_name)
    logger.debug "load_contribution_metadata: start - contribution_name[#{contribution_name}]"

    contrib = Contribution.find_by_name(contribution_name)

    repo = MetadataHelper::get_repo_by_collection(contrib.collection.name)

    #   compose query
    query = %(
      PREFIX alveo: <http://alveo.edu.au/schema/>
      PREFIX dcterms: <http://purl.org/dc/terms/>

      SELECT ?property ?value
      WHERE {
        ?contrib a alveo:Contribution.
        ?contrib dcterms:identifier "#{contrib.id}".
        ?contrib ?property ?value.
      }
    )

    # logger.debug "load_contribution_metadata: query[#{query}]"

    solutions = repo.sparql_query(query)

    if solutions.size != 0
      input = JSON.parse %(
      {
        "@id": "#{contrib.id}",
        "@type": "alveo:Contribution"
      })

      solutions.each do |solution|
        property = solution.to_h[:property].to_s
        value = solution.to_h[:value].to_s

        input[property] = value
      end
    end

    rlt = JSON::LD::API.compact(input, JsonLdHelper::default_context)

    logger.debug "load_contribution_metadata: rlt[#{rlt}]"

    return rlt
  end

  # To check whether user is the owner of specific contribution
  #
  # Only the contribution owner and admin can edit related contribution
  #
  def self.is_owner?(user, contribution)
    logger.debug "is_owner: start - user[#{user}], contribution[#{contribution}]"
    rlt = false

    if contribution.nil?
      # contribution is nil, no one is the owner
    else
      if user.nil?
        #   user is nil, nil user is not the owner
      else
        if contribution.owner.id == user.id || user.is_superuser?
          rlt = true
        end
      end
    end

    logger.debug "is_owner: end - rlt[#{rlt}]"

    rlt
  end


  #
  # Extract entry name (file name) from zip file. No extraction, just read from central directory.
  #
  # Return - array of hash, or string if failed
  #
  # rlt = [{
  #   :name => file base name,
  #   :size => file size
  # }]
  #
  #
  def self.entry_names_from_zip(zip_file)
    logger.debug "entry_names_from_zip: start - zip_file[#{zip_file}]"

    rlt = []

    begin
      Zip::File.open(zip_file) do |file|
        # Handle entries one by one
        file.each do |entry|
          if entry.ftype == :file
            rlt << {
              :name => File.basename(entry.name),
              :size => entry.size
            }
          end
        end
      end
    rescue Zip::Error => e
      rlt = e.message
    end

    logger.debug "entry_names_from_zip: end - rlt[#{rlt}]"

    return rlt
  end

  #
  # Validate contribution file.
  #
  # According to file name, retrieve associated document and item info.
  #
  # Input file is valid if:
  #
  # 1. Item name is part of the document name, it can be extracted from file name by specifying the delimiter and field number
  # * e.g., file name: 2_214_2_7_001-ch6-speaker16.TextGrid => item name: 2_214_2_7_001
  # split the document name with delimiter '-' and take field number [1] to extract the item name
  # * by default Alveo uses '-' as delimiter and take 1st field as item name
  #
  # 2. Item name is part of the document name, it is the first [_] characters of the file name
  # * e.g., file name: 12315_306_4_10_001.trs => item name: 12315
  # The first [5] characters compose the item name, then the new document name is '12315_306_4_10_001.trs'
  # (warning: we take the assumption that all file names have same length prefix for item nme)
  #
  # 3. Item has same name as file base name (without file extension)
  # * e.g., file name: 1_107_4_10_001.trs => item name: 1_107_4_10_001
  #
  # 4. Document has same name or is document name is prefix of file base name
  # * e.g., document name: 4_68_4_10.TextGrid.wav, then file 4_68_4_10.TextGrid or 4_68_4_10_for_test.TextGrid are both qualified to import
  # * this might be very slow once the collection contains large amount documents
  # e.g., file name: 2_192_2_7_001-ch6-speaker16.out, and a document named 2_192_2_7_001-ch6-speaker16.wav exists.
  #
  # Return hash:
  #
  # {
  #   :file => input file (basename),
  #   :item_handle => item.handle (e.g., mava:s203, nil if not found),
  #   :document_file_name => [document.file_name] (array of string, nil if not found),
  #   :dest_file => destination file name (basename), nil if validate failed
  #   :message => nil (no news is good news, otherwise error message)
  #   :mode => rename/overwrite
  # }
  #
  def self.validate_contribution_file(contribution_id, file, sep = {:type => 'delimiter', :delimiter => '-'})
    logger.debug "validate_contribution_file: start - contribution_id[#{contribution_id}], file[#{file}], sep[#{sep}]"

    contrib = Contribution.find_by_id(contribution_id)

    rlt = {
      :file => file,
      :item_handle => nil,
      :document_file_name => [],
      :dest_file => nil,
      :message => "no item/document found to associate with '#{file}'",
      :mode => nil
    }

    item = nil
    # result = []
    pattern = File.basename(file, ".*")
    collection = Collection.find_by_id(contrib.collection_id)
    item_handle = extract_handle(collection.name, pattern, sep)

    if sep[:type] == 'delimiter' || sep[:type] == 'offset' || sep[:type] == 'item'
      #   need to extract item name from file name
      item = Item.find_by_handle(item_handle)

      if !item.nil?
        # associated item found
        rlt[:item_handle] = item_handle
        rlt[:message] = nil
        rlt[:dest_file] = file
      end
    else
      # type is 'doc'
      # need to find associated item/document by file name
      # in large collection (e.g., austalk) this might has performance issue

      sql = %(
        SELECT
          i.handle as item_handle, d.file_name as document_file_name, cm.contribution_id as contribution_id
        FROM
          items i, documents d
        LEFT OUTER JOIN contribution_mappings cm
          ON d.id = cm.document_id
        WHERE
          i.collection_id = #{contrib.collection_id}
          AND d.item_id = i.id
          AND d.file_name like '#{pattern}%'
        ORDER BY d.file_name
        )

      result = ActiveRecord::Base.connection.execute(sql)

      if result.count > 0
        #   associated document found

        # check single item
        item_handles = result.map {|e| e["item_handle"]}
        if item_handles.uniq.length > 1
          # multiple items found, can't continue
          rlt[:message] = "no unique item (#{item_handles.uniq}) found to associate with '#{file}', please use one of the other methods to match files to items"
        else
          # unique item found

          # find dest file name
          name_result = next_available_name(
            contribution_id,
            file,
            result.map {|e| {
              :name => e["document_file_name"],
              :item_handle => e["item_handle"],
              :contrib_id => e["contribution_id"]}}
          )

          rlt[:message] = nil
          rlt[:item_handle] = item_handles[0]
          rlt[:dest_file] = name_result[:file_name]
          rlt[:document_file_name] = result.map {|e| e["document_file_name"]}
          rlt[:mode] = name_result[:mode]

          case rlt[:mode]
          when "rename"
            rlt[:message] = "Duplicated document found[#{file}]. New file would be renamed as '#{rlt[:dest_file]}'."
          when "overwrite"
            rlt[:message] = "Duplicated document found[#{file}]. Existing file would be overwritten as '#{rlt[:dest_file]}'."
          end
        end
      end
    end

    logger.debug "validate_contribution_file: end - rlt[#{rlt}]"

    return rlt
  end

  #
  # Extract item handle from file name according to separator
  #
  # default： separator is '-'， offset_number is -1
  #
  # return nil if file name violate convention
  #
  def self.extract_handle(collection_name, file_name, sep = {:type => 'delimiter', :delimiter => '-'})
    rlt = nil

    delimiter = '-'
    field = 1
    offset_number = -1

    if !sep[:delimiter].nil?
      delimiter = sep[:delimiter]
    end

    if !sep[:field].nil?
      field = sep[:field]
    end

    if !sep[:offset].nil?
      offset_number = sep[:offset]
    end

    begin
      if sep[:type] != 'item'
        if offset_number != -1
          rlt = "#{collection_name}:#{file_name[0..offset_number - 1]}"
        else
          rlt = "#{collection_name}:#{file_name.split(delimiter)[field - 1]}"
        end
      else
        #   type 'item', item name is file base name
        rlt = "#{collection_name}:#{File.basename(file_name)}"
      end
    rescue Exception => e
      logger.warn "extract_handle: #{e.message}, collection_name[#{collection_name}], file_name[#{file_name}], sep[#{sep}]"
    end

    logger.debug "extract_handle: end - collection_name[#{collection_name}], file_name[#{file_name}], sep[#{sep}] => rlt[#{rlt}]"

    return rlt
  end

  #
  # Import document into contribution.
  #
  # Return: result (string)
  #
  # - success: xx document(s) imported.
  # - failed: failed message
  #
  def self.import(contribution, sep = {:delimiter => '-'})
    logger.debug "import: start - contribution[#{contribution}], sep[#{sep}]"

    rlt = "import failed - "
    # run preview again to ensure zip file ok
    contrib_doc = preview_import(contribution, sep)

    # ensure no failed doc
    failed_doc = []
    if contrib_doc.is_a?(Array)
      contrib_doc.each do |d|
        if !d[:message].nil? && d[:dest_file].nil?
          failed_doc << d[:message]
        end
      end
    else
      #   sth error happened
      rlt += contrib_doc.to_s
      logger.error "import: rlt[#{rlt}]"

      return rlt
    end

    if failed_doc.size > 0
      #   failed doc found
      rlt += failed_doc.join("; ")
    else
      # unzip file
      zip_file = contribution_import_zip_file(contribution)
      unzip_dir = File.join(File.dirname(zip_file), File.basename(zip_file, ".zip"))

      extracted_file = unzip(zip_file, unzip_dir)
      if extracted_file.is_a? String
        #   sth wrong happened
        logger.error "import: return from unzip: #{extracted_file}"
        rlt = extracted_file

        return rlt
      end

      contrib_doc.each do |doc|
        begin
          contrib_id = contribution.id
          item_handle = %(#{contribution.collection.name}:#{doc[:item]})
          # find full path thru :name mapping
          extracted_filepath = (extracted_file.select {|e| e[:name] == doc[:name]}.first)[:dest_name]

          # move(rename): from extracted file to destination file
          doc_file = File.join(File.dirname(extracted_filepath), doc[:dest_file])
          if extracted_filepath != doc_file
            FileUtils.mv(extracted_filepath, doc_file)
          end

          overwrite = (doc[:mode] == 'overwrite') ? true : false

          add_document_to_contribution(contrib_id, item_handle, doc_file, overwrite)
            # logger.info "import: contribution_id[#{contrib_id}], item_handle[#{item_handle}], doc_file[#{doc_file}]"

        rescue Exception => e
          logger.error "import: exception happened during add document to contribution [#{e.message}]"

          rlt += "#{e.message}"

          return rlt
        end
      end

      # finally, get there
      # clean up
      FileUtils.rm_f(zip_file)
      FileUtils.rm_rf(unzip_dir)

      rlt = "OK! #{contrib_doc.size} document(s) imported."
    end

    logger.debug "import: end - rlt[#{rlt}]"

    return rlt
  end

  #
  # Unzip contribution's import zip file to specific dir.
  #
  # Return:
  #
  # - success: array of hash
  #   rlt = [
  #     {
  #       :name => file name (basename),
  #       :dest_name => extracted file name (full path)
  #     }
  #   ]
  # - failed: string (message)
  def self.unzip(zip_file, unzip_dir)
    logger.debug "unzip: start - zip_file[#{zip_file}], unzip_dir[#{unzip_dir}]"
    rlt = []

    # init unzip_dir
    FileUtils.mkdir_p(unzip_dir)

    begin
      Zip::File.open(zip_file) do |zf|
        # Handle entries one by one
        zf.each do |entry|
          # init dest file
          dest_name = File.join(unzip_dir, entry.name)
          FileUtils.mkdir_p(File.dirname(dest_name))
          FileUtils.rm_f(dest_name)

          entry.extract(dest_name)

          rlt << {
            :name => File.basename(entry.name),
            :dest_name => dest_name
          }
        end
      end
    rescue Zip::Error => e
      logger.error "unzip: #{e.message}"
      rlt = e.message
    end

    logger.debug "unzip: end - rlt[#{rlt}]"

    return rlt
  end

  #
  # Add document to contribution.
  #
  # - Document (file) already exists.
  # - file already validated
  #
  #
  def self.add_document_to_contribution(contribution_id, item_handle, doc_file, overwrite = false)
    logger.debug "add_document_to_contribution: start - contribution_id[#{contribution_id}], item_handle[#{item_handle}], doc_file[#{doc_file}], overwrite[#{overwrite}]"

    # compose file attr
    contribution = Contribution.find_by_id(contribution_id)

    # /data/contrib/:collection_name/:contrib_id/:filename
    contrib_dir = contribution_dir(contribution)

    # # get available file name
    # name_result = next_available_name(contribution_id)

    file_path = File.join(contrib_dir, File.basename(doc_file))
    logger.debug "add_document_to_contribution: processing [#{file_path}]"

    # copy extracted document file from temp to corpus dir
    logger.debug("add_document_to_contribution: copying document file from #{doc_file} to #{file_path}")
    FileUtils.cp(doc_file, file_path)

    contrib_metadata = JSON.parse(%(
    {
      "alveo:Contribution": "#{contribution_id}"
    }))

    doc_json = JsonLdHelper.construct_document_json_ld(
      contribution.collection,
      Item.find_by_handle(item_handle),
      "eng - English",
      file_path,
      contrib_metadata)

    CollectionsHelper.add_document_core(contribution.collection, Item.find_by_handle(item_handle), doc_json, file_path, overwrite)

  end

  # extract document type from file basename
  #
  # Use gem "mimemagic" to handle this (at this version only by extension).
  #
  # File's document type is media type. e.g.,
  #
  # test.mp4: mediatype[video], subtype[mp4]
  # test.txt: mediatype[text], subtype[plain]
  #
  def self.extract_doc_type(file)
    rlt = MimeMagic.by_path(file)
    if rlt.nil?
      rlt = "application"
    else
      rlt = rlt.mediatype
    end

    return rlt
  end

  #
  # Return array of hash:
  #
  # {
  #   :mp_id => mapping id
  #   :item_name => name of associated item
  #   :document_file_name => file name of associated document
  #   :document_doc_type => file type of associated document
  # }
  def self.load_contribution_mapping(contribution)
    mappings = ContributionMapping.where(:contribution_id => contribution.id)

    rlt = []

    mappings.each do |mp|
      doc = Document.find_by_id(mp.document_id)
      item = Item.find_by_id(mp.item_id)
      if !doc.present? || !item.present?
        logger.info "load_contribution_mappings: contribution_id[#{contribution.id}], doc[#{mp.document_id}] or item[#{mp.item_id}] not present, so skip"
        next
      end

      hash = {
        :mp_id => mp.id,
        :item_name => Item.find_by_id(mp.item_id).get_name,
        :document_file_name => doc.file_name,
        :document_doc_type => doc.doc_type
      }

      rlt << hash
    end

    logger.debug "load_contribution_mapping: end - rlt[#{rlt}]"

    return rlt
  end

  #
  # Load import preview according to contribution.
  #
  # 0. locate zip file according to contribution (contrib dir)
  # 1. extract entry info (zipped file info, but not extract whole zip)
  # 2. check file one by one
  # 3. return all files' preview info (can import or not, reason)
  #
  # Return: array of hash, or string is error
  #
  # rlt = [
  #   {
  #     :name => file base name,
  #     :size => file size,
  #     :type => file type,
  #     :item => associated item name,
  #     :document => associated document name,
  #     :dest_file => destination file base name, nil if validate failed
  #     :message => error message (no news is good news, nil is good)
  #     :mode => 'rename'/'overwrite'
  #   }
  # ]
  #
  def self.preview_import(contribution, sep = {:delimiter => '-'})
    logger.debug "preview_import: start - contribution[#{contribution.name}], sep[#{sep}]"

    rlt = []

    # locate zip file
    zip = contribution_import_zip_file(contribution)

    doc_files = entry_names_from_zip(zip)

    if doc_files.is_a? String
      rlt = doc_files
      logger.error "preview_import: rlt[#{rlt}]"
      return rlt
    end

    doc_files.each do |f|
      #   check file one by one
      vld_rlt = validate_contribution_file(contribution.id, f[:name], sep)

      rlt << {
        :name => f[:name],
        :size => f[:size],
        :type => extract_doc_type(f[:name]),
        :item => (vld_rlt[:item_handle].split(":").last unless vld_rlt[:item_handle].nil?),
        :document => (vld_rlt[:document_file_name] unless vld_rlt[:document_file_name].nil?),
        :dest_file => vld_rlt[:dest_file],
        :message => vld_rlt[:message],
        :mode => vld_rlt[:mode]
      }

    end

    logger.debug "preview_import: end - rlt[#{rlt}]"

    rlt
  end

  #
  # Find next available file name (if duplicated name exits) for contribution import.
  #
  # process rule:
  #
  # - overwrite
  #   - if collection-document, can't overwrite, need to rename (rules below)
  #   - if contribution-document within same contribution, just overwrite (easiest to implement)
  #
  # - rename
  #   - auto suffix (goal: make it easy to identify all of these files as being associated with each other)
  #   - e.g., user upload file.txt via contrib x (id: x)
  #    - if collection-document file.txt exists (from different contribution)
  #    - rename current file to file-cx.txt (suffix "-cx", means from contribution x). if file-cx.txt already exits, refer to following rules.
  #    - if contribution-document file.txt exists (from same contribution)
  #     - overwrite file.txt
  #    - if contribution-document file.txt exists (from different contribution, but two contributions associated to same collection)
  #     - rename to file-cx.txt
  #
  # Return: string hash
  #
  # {
  #   :item_handle => associated item handle
  #   :file_name => available file name
  #   :mode => "overwrite/rename/nil"
  # }
  #
  def self.next_available_name(contrib_id, src_file, existing_files)
    logger.debug "next_available_name: start - contrib_id[#{contrib_id}], src_file[#{src_file}], existing_files[#{existing_files}]"

    rlt = {:item_handle => nil, :file_name => "#{src_file}", :mode => nil}

    existing_files.each do |f|
      rlt[:item_handle] = f[:item_handle]

      if f[:name] == src_file
        #   duplicated file found
        #   check contribution
        if f[:contrib_id].to_s == contrib_id.to_s
          #   same contribution with src file, overwrite mode
          rlt[:mode] = "overwrite"
          logger.debug "next_available_name: rlt[#{rlt}]"
          break
        else
          #   collection document or different contribution, rename mode
          #   abc.txt => abc-cx.txt ('c' for contribution, 'x' is contribution id)
          dest_file = File.basename(src_file, File.extname(src_file)) + "-c#{contrib_id}" + File.extname(src_file)

          # further check dest_file available
          rlt = next_available_name(contrib_id, dest_file, existing_files)
          rlt[:mode] = "rename"
        end
      end
    end

    logger.debug "next_available_name: end - rlt[#{rlt}]"

    return rlt

  end

  #
  # zip file name:
  #
  # APP_CONFIG["contrib_dir"] (config/hcsvlab-web_config.yml: contrib_dir)
  #
  def self.contribution_import_zip_file(contribution)
    rlt = nil

    if !contribution.nil?
      rlt = File.join(APP_CONFIG["contrib_dir"], contribution.collection.name, "import_#{contribution.id.to_s}.zip")
    end

    rlt
  end

  #
  # directory name:
  #
  # APP_CONFIG["contrib_dir"] (config/hcsvlab-web_config.yml: contrib_dir)
  #
  def self.contribution_dir(contribution)
    rlt = nil

    if !contribution.nil?
      begin
        rlt = File.join(APP_CONFIG["contrib_dir"], contribution.collection.name, contribution.id.to_s)
      rescue Exception => e
        logger.error "contribution_dir: #{e.message}"
      end
    end

    return rlt
  end


  #
  # Call CollectionHelper.delete_doc_core to delete document
  #
  # One contribution associates to 1 collection, multiple items and multiple documents.
  #
  # Return hash:
  #
  # {
  #   message: failure reason, nil if success (no news is good news)
  #   document_count: deleted document count (nil if delete failure)
  # }
  #
  def self.delete_contribution(contribution)
    logger.debug "delete_contribution: start - contribution[#{contribution}]"
    rlt = {message: nil, document_count: 0}

    collection = contribution.collection
    # contrib_dir = contribution_dir(contribution)

    begin
      result = ContributionMapping.where(:contribution_id => contribution.id)
      # delete all related document one-by-one
      logger.debug "delete_contribution: result count[#{result.count}]"
      rlt[:document_count] = result.count
      result.each do |row|
        item = Item.find_by_id(row.item_id)
        document = Document.find_by_id(row.document_id)

        CollectionsHelper.delete_document_core(collection, item, document)
      end

      #   delete related contribution mapping
      ContributionMapping.delete_all(contribution_id: contribution.id)

      # delete contribution
      contribution.destroy

      #   delete contribution in sesame
      repo = MetadataHelper.get_repo_by_collection(collection.name)

      uri = Rails.application.routes.url_helpers.contrib_show_url(contribution.id)
      query = %(
        DELETE {?s ?p ?o.}
        WHERE {
          ?s ?p ?o.
          FILTER(?s = <#{uri}>)
        }
      )

      logger.debug "delete_contribution: sparql query[#{query}]"

      repo.sparql_query(query)

    rescue Exception => e
      logger.error "delete_contribution: #{e.inspect}"
      rlt[:message] = e.message
    end

    logger.debug "delete_contribution: end - rlt[#{rlt}]"

    rlt
  end

  #
  # Export contribution document files and related collection document files as zip file.
  #
  # Because contribution document files are related to item but not specific document, so when export with wildcard, the files are actually from related items (thru contribution_mappings).
  #
  # So finally this is equal to export files as zip from item documents.
  #
  # @param contribution specific contribution
  # @param wildcard String pattern
  #
  # Return zip file path if success , otherwise exception throws
  #
  def self.export_as_zip(contribution, wildcard = '*')
    logger.debug "export_as_zip: start - contribution[#{contribution}], wildcard[#{wildcard}]"

    rlt = nil

    begin
      # retrieve file path
      file_hash = all_related_files(contribution, wildcard)

      logger.debug "export_as_zip: file_hash[#{file_hash}]"

      if file_hash.empty?
        raise Exception.new("cannot find any file with wildcard match: #{wildcard}")
      end

      # generate manifest.json
      m_json, file_details = manifest_json(file_hash)
      m_json_dir = File.join(APP_CONFIG['download_tmp_dir'], "contrib_export_#{contribution.id}_#{Time.now.getutc.to_i.to_s}")
      FileUtils.mkdir_p(m_json_dir)
      m_json_file = File.join(m_json_dir, "manifest.json")
      File.open(m_json_file, "w") do |f|
        f.write(m_json.to_json)
      end

      file_details << File.absolute_path(m_json_file)

      # generate zip path
      zip_path = File.join(APP_CONFIG['download_tmp_dir'], "contrib_export_#{contribution.id}_#{Time.now.getutc.to_i.to_s}.zip")

      # zip it
      ZipBuilder.build_simple_zip_from_files(zip_path, file_details)

      rlt = zip_path
    rescue Exception => e
      logger.error "export_as_zip: #{e.message}"
      raise Exception.new(e.message)
    end

    logger.debug "export_as_zip: end - rlt[#{rlt}]"

    return rlt
  end

  # @param [Hash] file_hash
  # {
  #   "item_handle_1": {
  #     "uri": "https://.../item_name_1",
  #     "files": [
  #       "file full path 1",
  #       "file full path 2"
  #     ]
  #   }
  # }
  #
  # @return [Hash], [Array of String]
  # {
  #   "item_handle_1": {
  #     "uri": "https://.../item_name_1",
  #     "files": [
  #       {
  #         "name": "file_1.wav",
  #         "size": "123"
  #       },
  #       {
  #         "name": "file_2.wav",
  #         "size": "345"
  #       },
  #       {
  #         "name": "file_3.wav",
  #         "size": "",
  #         "missing": "file not found"
  #       }
  #     ]
  #   }
  # },
  # [file_path]
  def self.manifest_json(file_hash)
    logger.debug "manifest_json: start - file_hash[#{file_hash}]"
    rlt = {}
    rlt_files = []

    file_hash.each do |handle, value|
      if !rlt.has_key? (handle)
        rlt[handle] = {}
      end

      rlt[handle][:uri] = file_hash[handle][:uri]

      files = []
      file_hash[handle][:files].each do |file_path|
        # 0 byte file treated as normal file
        file_name = File.basename(file_path)
        file = {"name" => file_name, "size" => "", "missing" => "file not found"}
        if File.file?(file_path)
          file = {"name" => file_name, "size" => File.absolute_path(file_path).size}
          rlt_files << file_path
        end

        files << file
      end

      rlt[handle][:files] = files
    end

    logger.debug "manifest_json: end - rlt[#{rlt}], rlt_files[#{rlt_files}]"

    return rlt, rlt_files

  end

  # Retrieve all related document files from related items thru collection_mappings.
  #
  # @param [Contribution] contribution - specific contribution
  # @param [String] wildcard
  # @return [Hash] {item_handle => {:uri => item uri, :files => [document file_path]} }
  def self.all_related_files(contribution, wildcard = '*')
    logger.debug "all_related_files: start - contribution[#{contribution}], wildcard[#{wildcard}]"

    rlt = {}

    # convert wildcard
    if wildcard.nil?
      wildcard = ''
    else
      # remove '*' and blank character, then replace ',' with '|'
      wildcard = wildcard.gsub('*', '').gsub(/\s+/, '').gsub(',', '|').downcase
    end

    if !contribution.nil?
      sql = %(
        select distinct i.handle, i.uri, d.file_path
        from contribution_mappings cm, documents d, items i
        where
          cm.contribution_id=#{contribution.id}
          and cm.item_id=i.id
          and i.id=d.item_id
          and lower(d.file_name) similar to '%(#{wildcard})%';
      )

      result = ActiveRecord::Base.connection.execute(sql)
      # if result.count > 0
      #   rlt = result.map{|e| e["file_path"]}
      # end

      result.each do |row|
        handle = row["handle"]
        uri = row["uri"]
        file_path = row["file_path"]

        if !rlt.has_key? (handle)
          rlt[handle] = {}
        end

        rlt[handle][:uri] = uri

        if !rlt[handle].has_key? (:files)
          rlt[handle][:files] = []
        end

        rlt[handle][:files] << file_path
      end
    end

    logger.debug "all_related_files: end - rlt[#{rlt}]"
    return rlt
  end

  # Upsert contribution in DB and Sesame
  #
  # attr:
  #
  # - :name contrib name
  # - :owner contrib owner (current_user)
  # - :collection related collection (name)
  # - :description contrib description
  # - :abstract contrib abstract
  # - :file uploaded file
  #
  def self.upsert_contribution_core(attr)
    logger.debug "upsert_contribution_core: start - attr[#{attr}]"

    query = ""
    msg = ""
    proceed_sesame = false

    if !attr[:id].nil?
      #   contribution contains id => update
      contrib = Contribution.find_by_id(attr[:id])
    else
      contrib = Contribution.find_by_name(attr[:name])
    end

    contrib_abstract = attr[:abstract]

    if contrib.nil?
      #   contribution not exist, create a new one

      # DB
      contrib = Contribution.new
      contrib.name = attr[:name]
      contrib.owner = attr[:owner]
      contrib.collection = Collection.find_by_name(attr[:collection])
      contrib.description = attr[:description]
      contrib.save!

      # retrieve contribution id to compose uri
      collection_uri = UrlGenerator.new.collection_url(contrib.collection.name)
      uri = UrlGenerator.new.contrib_show_url(contrib.id)

      # compose query
      #
      # e.g.,
      #
      # PREFIX alveo: <http://alveo.edu.au/schema/>
      # PREFIX dcterms: <http://purl.org/dc/terms/>
      #
      # INSERT DATA {
      #   <http://localhost:3000/contrib/9> a alveo:Contribution;
      #   dcterms:identifier "9";
      #   dcterms:isPartOf "https://app.alveo.edu.au/catalog/austalk";
      #   dcterms:title "19Oct.1";
      #   dcterms:creator "Data Owner";
      #   dcterms:created "2017-10-18 23:35:08 UTC";
      #   dcterms:abstract "anyway...".
      # }

      query = %(
        PREFIX alveo: <http://alveo.edu.au/schema/>
        PREFIX dcterms: <http://purl.org/dc/terms/>

        INSERT DATA {
          <#{uri}> a alveo:Contribution;
          dcterms:identifier "#{MetadataHelper.sqarql_well_formed(contrib.id)}";
          dcterms:isPartOf "#{collection_uri}";
          dcterms:title "#{MetadataHelper.sqarql_well_formed(contrib.name)}";
          dcterms:creator "#{MetadataHelper.sqarql_well_formed(contrib.owner.full_name)}";
          dcterms:created "#{MetadataHelper.sqarql_well_formed(contrib.created_at)}";
          dcterms:abstract "#{MetadataHelper.sqarql_well_formed(contrib_abstract)}".
        }
      )

      msg = "New contribution '#{contrib.name}' (#{uri}) created"
      proceed_sesame = true

    else
      # contribution exists, just update
      # only name, description in DB need to be updated
      if !attr[:name].nil?
        contrib.name = attr[:name]
      end
      contrib.description = attr[:description]
      contrib.save!

      # retrieve contribution id to compose uri
      uri = UrlGenerator.new.contrib_show_url(contrib.id)

      # compose query
      #
      # Uses 2 operations, so no matter resource <https://app.alveo.edu.au/contrib/999> exists or not, it would update (delete then insert) for sure
      #
      # e.g.,
      #
      # PREFIX alveo: <http://alveo.edu.au/schema/>
      # PREFIX dcterms: <http://purl.org/dc/terms/>
      #
      # DELETE WHERE {
      #   ?contrib ?property ?value.
      #   ?contrib a alveo:Contribution .
      #   ?contrib dcterms:identifier "999" .
      # };
      #
      # INSERT DATA {
      #   <https://app.alveo.edu.au/contrib/999> a alveo:Contribution;
      #   dcterms:identifier "999";
      #   dcterms:title "Austalk Manual Transcriptions";
      #   dcterms:creator "Steve Cassidy";
      #   dcterms:created "2018-03-13 00:09:13 UTC";
      #   dcterms:abstract "blahblah".
      # }

      query = %(
        PREFIX alveo: <http://alveo.edu.au/schema/>
        PREFIX dcterms: <http://purl.org/dc/terms/>

        DELETE WHERE {
          ?contrib ?property ?value.
          ?contrib a alveo:Contribution .
          ?contrib dcterms:identifier "#{contrib.id}" .
        };

        INSERT DATA {
          <#{uri}> a alveo:Contribution;
          dcterms:identifier "#{MetadataHelper.sqarql_well_formed(contrib.id)}";
          dcterms:title "#{MetadataHelper.sqarql_well_formed(contrib.name)}";
          dcterms:creator "#{MetadataHelper.sqarql_well_formed(contrib.owner.full_name)}";
          dcterms:created "#{MetadataHelper.sqarql_well_formed(contrib.created_at)}";
          dcterms:abstract "#{MetadataHelper.sqarql_well_formed(contrib_abstract)}".
        }
      )

      # start to process document part

      if attr[:file].nil?
        # no file uploaded
        msg = "Contribution '#{contrib.name}' (#{uri}) updated"
        proceed_sesame = true
      else
        # validate file to be added to contribution
        vld_rlt = ContributionsHelper.validate_contribution_file(contrib.id, attr[:file])

        if vld_rlt[:error].nil?
          # no news is good news, validation passed
          add_rlt = ContributionsHelper.add_document_to_contribution(contrib.id, vld_rlt[:item_handle], attr[:file], vld_rlt[:mode])
          msg = "Contribution '#{contrib.name}' (#{uri}) updated"
        else
          msg = "Contribution '#{contrib.name}' (#{uri}) update failed: #{vld_rlt[:error]}"
        end
      end
    end

    # sesame repo
    if proceed_sesame
      repo = MetadataHelper.get_repo_by_collection(contrib.collection.name)

      logger.debug "upsert_contribution_core: sparql query[#{query}]"

      repo.sparql_query(query)
    end

    logger.debug "upsert_contribution_core: end - contrib.id[#{contrib.id}]"

    return msg, contrib.id

  end

  # check whether specific user has access right to specific contribution
  #
  # At this stage, contribution is accessible to all registered user
  def self.accessible(user, contrib_id)
    logger.debug "accessible: start - user[#{user}], contrib_id[#{contrib_id}]"
    rlt = false

    contrib = Contribution.find_by_id(contrib_id)

    if user.present? && contrib.present?
      rlt = true
    end

    logger.debug "accessible: end - rlt[#{rlt}]"
    return rlt
  end

end

