require "#{Rails.root}/lib/rdf-sesame/hcsvlab_server.rb"
require Rails.root.join('lib/tasks/fedora_helper.rb')

module CollectionsHelper

  VT_CONFIG = YAML.load_file("#{Rails.root.to_s}/config/voyant_tools.yml")[Rails.env] unless defined? VT_CONFIG

  # To check whether user is the owner of specific collection
  def self.is_owner(user, collection)
    logger.debug "is_owner: start - user[#{user}], collection[#{collection}]"
    rlt = false

    if collection.nil?
      # collection is nil, no one is the owner
    else
      if user.nil?
        #   user is nil, nil user is not the owner
      else
        if collection.owner.id == user.id || user.is_superuser?
          rlt = true
        end
      end
    end

    logger.debug "is_owner: end - rlt[#{rlt}]"

    rlt
  end

  #
  # Core functionality common to add document ingest (via api and web app)
  #
  # args:
  # collection - collection instance
  # item - item instance
  # document_metadata - hash
  # document_file - document file path
  # overwrite - to overwrite existing document (true/false), default is false
  #
  def self.add_document_core(collection, item, document_metadata, document_file, overwrite=false)
    doc_id, msg = create_document(item, document_metadata, overwrite)
    add_and_index_document(item, document_metadata)
    "Added the document #{File.basename(document_file)} to item #{item.get_name} in collection #{collection.name}"

    # check contribution mapping
    # if overwrite is true, don't need to modify existing mapping
    if !document_metadata["alveo:Contribution"].nil? && !doc_id.nil? && !overwrite
      logger.debug "add_document_core: create contribution_mapping between contribution[#{document_metadata["alveo:Contribution"]}] and document[#{doc_id}]"
      # create association between contribution and document
      contrib_mapping = ContributionMapping.new
      contrib_mapping.contribution_id = document_metadata["alveo:Contribution"]
      contrib_mapping.item_id = item.id
      contrib_mapping.document_id = doc_id

      contrib_mapping.save!
    end
  end

  # Create a document in the database from Json-ld document metadata.
  #
  # If document exists and overwrite is true, then overwrite existing document.
  #
  # Return:
  #
  # - document id (nil if failed)
  # - message (if created successfully nil, otherwise error message)
  def self.create_document(item, document_json_ld, overwrite=false)

    expanded_metadata = JSON::LD::API.expand(document_json_ld).first

    uri = expanded_metadata[MetadataHelper::SOURCE.to_s].first['@id']
    if uri.nil?
      uri = expanded_metadata[MetadataHelper::SOURCE.to_s].first['@value']
    end

    file_path = URI(uri).path
    file_name = File.basename(file_path)
    doc_type = expanded_metadata[MetadataHelper::TYPE.to_s]
    doc_type = ContributionsHelper.extract_doc_type(file_name) unless doc_type.nil?
    msg = nil

    document = item.documents.find_or_initialize_by_file_name(file_name)
    if document.new_record? || overwrite
      begin
        document.file_path = file_path
        document.doc_type = doc_type
        document.mime_type = mime_type_lookup(file_name)
        document.item = item
        document.item_id = item.id
        document.save

        logger.info "create_document: #{doc_type} Document = #{document.id.to_s} overwrite[#{overwrite}]"
      rescue Exception => e
        logger.error "create_document: Error creating document: #{e.message}, metadata[#{expanded_metadata}], overwrite[#{overwrite}]"
        document.id = nil
        msg = e.message
      end
    else
      raise ResponseError.new(409), "A file named #{file_name} is already in use by another document of item '#{item.get_name}'"
    end

    return document.id, msg
  end

  # Adds a document to Sesame and updates the corresponding item in Solr
  def self.add_and_index_document(item, document_json_ld)
    add_and_index_document_in_sesame(item.id, document_json_ld)

    # Reindex item in Solr
    delete_item_from_solr(item.id)
    item.indexed_at = nil
    item.save
    update_item_in_solr(item)
  end

  # Updates the item in Solr by re-indexing that item
  def self.update_item_in_solr(item)
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

  #
  # Delete document. Remove DB/Sesame/Solr/Filesystem associated record/file.
  #
  # Return string of result
  #
  def self.delete_document_core(collection, item, document)
    remove_document(document, collection)
    delete_item_from_solr(item.id)
    item.indexed_at = nil
    item.save
    update_item_in_solr(item)
    "Deleted the document #{document.file_name} from item #{item.get_name} in collection #{collection.name}"

  end

  # Removes a document from the database, filesystem, Sesame and Solr
  def self.remove_document(document, collection)
    solr_worker = Solr_Worker.new
    solr_worker.delete_document(document)

    document.destroy # Remove document and document audits from database
  end

  # Returns a collection repository from the Sesame server
  def self.get_sesame_repository(collection)
    server = RDF::Sesame::HcsvlabServer.new(SESAME_CONFIG["url"].to_s)
    server.repository(collection.name)
  end

  # To check whether user can access collection.
  #
  # According to below access control table:
  #
  # 1. Accessible to collection list (/catalog)
  # Status    Guest   Admin   User(Owner)   User(Non-owner)
  # DRAFT       N       Y         Y             N*
  # RELEASED    Y       Y         Y             Y
  # FINALISED   Y       Y         Y             Y
  #
  # * Non-owner can’t see draft collection until granted permission by owner
  #
  # 2. Accessible to collection detail (/catalog/:id)
  # Status    Guest   Admin   User(Owner)   User(Non-owner)
  # DRAFT       N*1     Y         Y             N*3
  # RELEASED    Y*2     Y         Y             Y*4
  # FINALISED   Y*2     Y         Y             Y*4
  #
  # *1 require guest to log in to proceed
  # *2 if collection set as private, guest can’t access (require login)
  # *3 non-owner user can’t see draft collection until granted permission by owner
  # *4 if collection set as private, user would be redirected to licence manage page to accept licence agreement (if not approved yet) or access collection directly (if already approved)
  #
  # 3. Accessible to collection edit (/catalog/:id/edit)
  # Status    Guest   Admin   User(Owner)   User(Non-owner)
  # DRAFT       N*1     Y         Y             N*3
  # RELEASED    N*1     Y         Y             N
  # FINALISED   N*1     Y         N*2           N
  #
  # *1 require guest to log in to proceed
  # *2 need to contact admin for further edit action
  # *3 co-edit draft feature is not implemented yet
  #
  # Return:
  # {
  #   :read => 0 - yes; other - no with return code
  #   :show => 0 - yes; other - no with return code
  #   :edit => 0 - yes; other - no with return code
  # }
  # or
  # nil - collection is nil (user is nil means guest user)
  #
  # Return code:
  # 0   - OK
  # 10  - Need login to proceed.
  # 20  - Need draft access permission to proceed.
  # 30  - Need private access permission to proceed.
  # 40  - Need admin permission to proceed.
  #
  def self.collection_accessible?(collection, user)
    logger.debug "collection_accessible?: start - collection[#{collection}, user[#{user}]"

    rlt = nil

    if collection.nil? || collection.name.nil?
      msg = "Collection is nil"
      logger.warn "collection_accessible?: #{msg}"
    else
      # check user type
      case
        when user.nil?
          # guest
          # assume guest can read/show
          rlt = {
            :read => 0,
            :show => 0,
            :edit => 10
          }

          # check collection status
          if collection.is_draft? || !collection.is_public?
            rlt = {
              :read => 10,
              :show => 10,
              :edit => 10
            }
          end
        when user.is_superuser?
          # admin
          # at first, assume admin can do everything...
          rlt = {
            :read => 0,
            :show => 0,
            :edit => 0
          }

          if collection.is_finalised?
            # even admin can't modify finalised collection directly, admin can only change collection's status from finalised to released.
            rlt[:edit] = 40
          end

          if !collection.is_public? && (collection.owner_id != user.id)
            info = user.get_collection_licence_info(collection)
            if info[:state] != :approved
              rlt[:show] = 30
              rlt[:edit] = 30
            end
          end

        when collection.owner_id == user.id
          # collection-owner
          logger.debug "collection_accessible?: user[#{user}] is the owner of collection[#{collection.name}]"
          # fine, this is your collection, assume you can do everything...
          rlt = {
            :read => 0,
            :show => 0,
            :edit => 0
          }

          if (collection.is_finalised?)
            # need admin approve to modify finalised collection
            rlt[:edit] = 40
          end
        else
          # non-collection-owner
          # by default, you can only read/show
          rlt = {
            :read => 0,
            :show => 0,
            :edit => 10
          }
          # check collection status
          if collection.is_draft?
            # check 'draft access' permission
            can_access_draft = draft_collection_by_user(user).include?(collection)
            if !can_access_draft
              rlt = {
                :read => 20,
                :show => 20,
                :edit => 20
              }
            end
          end

          # check collection private (licence agreement)
          if !collection.is_public?
            info = user.get_collection_licence_info(collection)
            if info[:state] != :approved
              rlt[:show] = 30
            end
          end
      end
    end

    logger.debug "collection_accessible?: end - rlt[#{rlt}]"

    return rlt
  end

  #
  # Retrieve accessible draft collections by user id
  #
  def self.draft_collection_by_user(user)
    # Collection.joins(:user_licence_requests).where("user_licence_requests.request_id = collections.id and user_licence_requests.request_type='draft_collection_read' and user_licence_requests.user_id = '#{user.id}'")
    Collection.joins("INNER JOIN user_licence_requests ON user_licence_requests.request_id::int8 = collections.id AND user_licence_requests.request_type = 'draft_collection_read' AND user_licence_requests.user_id = '#{user.id}'")
  end

  #
  # Generate Voyant-Tools link for collection
  #
  # 1. export collection document to zip file
  # 2. import zip file to Voyant-Tools server
  # 3. write corpus id to voyant_tools.yml
  #
  def self.gen_vt_link(collection_name, pattern='')
    logger.debug "gen_vt_link: start - collection[#{collection_name}], pattern[#{pattern}]"

    pid = spawn("#{Rails.root}/script/vt.sh #{collection_name} #{pattern}")
    Process.detach(pid)

    logger.debug "gen_vt_link: end - pid=#{pid}"
  end

  def self.is_voyant_server_on?
    logger.debug "voyant server is #{APP_CONFIG['voyant_server']}."
    return (APP_CONFIG["voyant_server"] == true)
  end

  #
  # Return doc filename according to collection and pattern
  #
  def self.filter_doc(collection_name, pattern, basename=true)
    logger.debug "filter_doc: start - collection[#{collection_name}], pattern[#{pattern}], basename[#{basename}]"

    rlt = []

    default_pattern = "%-plain.txt"
    if !pattern.present?
      pattern = default_pattern
    end

    pattern.gsub! "*", "%"

    # verify collection
    collection = Collection.find_by_name(collection_name)
    if !collection.present?
      msg = "collection '#{collection_name}' not found"
      logger.debug "filter_doc: #{msg}"
    else
      # collect document file path according to pattern
      begin
        sql = %(
        select d.file_path from collections c, items i, documents d
        where
          c.name='#{collection_name}'
          and i.collection_id=c.id
          and d.item_id=i.id
          and d.file_name like '#{pattern}'
          ;
      )
        result = ActiveRecord::Base.connection.execute(sql)

        if result.count > 0
          if basename
            rlt = result.map {|e| File.basename(e["file_path"])}
          else
            rlt = result.map {|e| e["file_path"]}
          end
        else
          #     no doc found according to current pattern
          msg = "no document found according to pattern '#{pattern}'"
          logger.debug "filter_doc: #{msg}"
        end
      rescue Exception => e
        logger.error "filter_doc: #{e.message}"
      end
    end

    logger.debug "filter_doc: end - rlt[#{rlt}]"

    return rlt
  end

end
