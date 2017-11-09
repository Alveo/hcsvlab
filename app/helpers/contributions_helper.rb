require Rails.root.join('lib/rdf-sesame/hcsvlab_server.rb')
require Rails.root.join('app/helpers/collections_helper.rb')
require 'zip'
require 'mimemagic'

module ContributionsHelper

  # include CollectionsHelper

  SESAME_CONFIG = YAML.load_file("#{Rails.root.to_s}/config/sesame.yml")[Rails.env] unless defined? SESAME_CONFIG

  # Load contribution's metadata, return json
  #
  #
  def self::load_contribution_metadata(contribution_name)
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

    logger.debug "load_contribution_metadata: query[#{query}]"

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
  def self::is_owner(user, contribution)
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
  def self::entry_names_from_zip(zip_file)
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
  # According to file name, retrieve associated document and item info. If input file
  # has the same file name as document file name (except the file ext), it is validated
  #
  # e.g., input file [abc.txt], if document file [abc.wav] exists in the same collection, this input file is validated.

  # However, if input file has the same name as document file, it is invalidated.
  #
  # Return hash.
  #
  # {
  #   :file => input file (basename),
  #   :item_handle => item.handle (e.g., mava:s203, nil if not found),
  #   :document_file_name => [document.file_name] (array of string, nil if not found),
  #   :message => nil (no news is good news, otherwise error message)
  # }
  #
  def self::validate_contribution_file(collection_id, file)
    logger.debug "validate_contribution_file: start - collection_id[#{collection_id}], file[#{file}]"

    rlt = {
      :file => file,
      :item_handle => nil,
      :document_file_name => [],
      :message => nil
    }

    # document files: abc.wav, abc_1.wav
    # if pattern is only "abc", both abc.wav and abc_1.wav would be retrieved.
    # so pattern should include the dot
    pattern = File.basename(file, ".*") + "."

    sql = %(
    SELECT
      i.handle as item_handle, d.file_name as document_file_name
    FROM
      items i, documents d
    WHERE
      i.collection_id = #{collection_id}
      AND d.item_id = i.id
      AND d.file_name like '#{pattern}%'
    )

    result = ActiveRecord::Base.connection.execute(sql)
    if result.count == 0
      rlt[:message] = "can't find existing document associated with [#{file}]"
    end

    result.each do |row|
      rlt[:item_handle] = row["item_handle"]
      rlt[:document_file_name] << row["document_file_name"]

      if (file == row["document_file_name"])
        #   input file has the same name as document file, invalidated
        rlt[:message] = "duplicated document file [#{file}]"
      end
    end

    logger.debug "validate_contribution_file: end - rlt[#{rlt}]"

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
  def self::import(contribution)
    logger.debug "import: start - contribution[#{contribution}]"

    rlt = "import failed - "
    # run preview again to ensure zip file ok
    contrib_doc = preview_import(contribution)

    # ensure no failed doc
    failed_doc = []
    if contrib_doc.is_a?(Array)
      contrib_doc.each do |d|
        if !d[:message].nil?
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

      extracted_file = unzip(zip_file)
      if extracted_file.is_a? String
        #   sth wrong happened
        logger.error "import: return from unzip: #{extracted_file}"
        rlt = extracted_file
      end

      contrib_doc.each do |doc|
        begin
          contrib_id = contribution.id
          item_handle = %(#{contribution.collection.name}:#{doc[:item]})
          # find full path thru :name mapping
          doc_file = (extracted_file.select {|e| e[:name] == doc[:name]}.first)[:dest_name]

          add_document_to_contribution(contrib_id, item_handle, doc_file)
            # logger.info "import: contribution_id[#{contrib_id}], item_handle[#{item_handle}], doc_file[#{doc_file}]"

        rescue Exception => e
          logger.error "import: exception happened during add document to contribution [#{e.message}]"

          rlt += "#{e.message}"

          return rlt
        end
      end

      # finally, get there
      # clean up
      FileUtils.rm_r(unzip_dir)
      FileUtils.rm(zip_file)

      rlt = "#{contrib_doc.size} document(s) imported."
    end

    logger.debug "import: end - rlt[#{rlt}]"

    return rlt
  end

  #
  # Unzip contribution's import zip file. All extracted files under directory named contribution_import_zip_file. e.g., import_123.zip(file) => import_123(dir)
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
  def self::unzip(zip_file)
    logger.debug "unzip: start - zip_file[#{zip_file}]"
    rlt = []

    unzip_dir = File.join(File.dirname(zip_file), File.basename(zip_file, ".zip"))
    FileUtils.mkdir_p(unzip_dir)

    begin
      Zip::File.open(zip_file) do |zf|
        # Handle entries one by one
        zf.each do |entry|
          entry.extract(File.join(unzip_dir, entry.name))

          rlt << {
            :name => File.basename(entry.name),
            :dest_name => File.join(unzip_dir, entry.name)
          }
        end
      end
    rescue Zip::Error => e
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
  def self::add_document_to_contribution(contribution_id, item_handle, doc_file)
    logger.debug "add_document_to_contribution: start - contribution_id[#{contribution_id}], item_handle[#{item_handle}], doc_file[#{doc_file}]"

    # compose file attr
    contribution = Contribution.find_by_id(contribution_id)

    # /data/contrib/:collection_name/:contrib_id/:filename
    contrib_dir = contribution_dir(contribution)
    file_path = File.join(contrib_dir, File.basename(doc_file))
    logger.debug "add_document_to_contribution: processing [#{file_path}]"

    doc_type = self::extract_doc_type(File.basename(file_path))

    # copy uploaded document file from temp to corpus dir
    logger.debug("add_document_to_contribution: copying document file from #{doc_file} to #{file_path}")


    # construct document Json-ld
    doc_uri = Item.find_by_handle(item_handle).uri + "/document/#{File.basename(file_path)}"

    doc_json = JSON.parse(%(
    {
      "@context": {
        "dcterms": "http://purl.org/dc/terms/",
        "foaf": "http://xmlns.com/foaf/0.1/",
        "alveo": "http://alveo.edu.au/schema/"
      },
      "@id": "#{doc_uri}",
      "@type": "foaf:Document",
      "alveo:Contribution": "#{contribution_id}",
      "dcterms:source": "#{file_path}",
      "dcterms:identifier": "#{File.basename(file_path)}",
      "dcterms:type": "#{doc_type}",
      "dcterms:title": "#{File.basename(file_path)}##{doc_type}"
    }))

    CollectionsHelper.add_document_core(contribution.collection, Item.find_by_handle(item_handle), doc_json, File.basename(file_path))

    # finally, get there
    FileUtils.cp(doc_file, file_path)

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

  def self::extract_doc_type(file)
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
  def self::load_contribution_mapping(contribution)
    mappings = ContributionMapping.where(:contribution_id => contribution.id)

    rlt = []

    mappings.each do |mp|
      doc = Document.find_by_id(mp.document_id)
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
  #     :message => error message (no news is good news, nil is good)
  #   }
  # ]
  #
  def self::preview_import(contribution)
    logger.debug "preview_import: start - contribution[#{contribution.name}]"

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
      vld_rlt = validate_contribution_file(contribution.collection.id, f[:name])

      rlt << {
        :name => f[:name],
        :size => f[:size],
        :type => extract_doc_type(f[:name]),
        :item => (vld_rlt[:item_handle].split(":").last unless vld_rlt[:item_handle].nil?),
        :document => (vld_rlt[:document_file_name] unless vld_rlt[:document_file_name].nil?),
        :message => vld_rlt[:message]
      }

    end

    logger.debug "preview_import: end - rlt[#{rlt}]"

    rlt
  end

  #
  # zip file name:
  #
  # APP_CONFIG["contrib_dir"] (config/hcsvlab-web_config.yml: contrib_dir)
  #
  def self::contribution_import_zip_file(contribution)
    rlt = nil

    if !contribution.nil?
      rlt = File.join(APP_CONFIG["contrib_dir"], contribution.collection.name, contribution.id.to_s, "import_#{contribution.id.to_s}.zip")
    end

    rlt
  end

  #
  # directory name:
  #
  # APP_CONFIG["contrib_dir"] (config/hcsvlab-web_config.yml: contrib_dir)
  #
  def self::contribution_dir(contribution)
    rlt = File.join(APP_CONFIG["contrib_dir"], contribution.collection.name, contribution.id.to_s)

    return rlt
  end


  def self.delete_document(document)

  end

end

