require Rails.root.join('lib/tasks/fedora_helper.rb')
require Rails.root.join('lib/api/response_error')
require Rails.root.join('lib/api/request_validator')
require Rails.root.join('lib/json-ld/json_ld_helper.rb')
require Rails.root.join('app/helpers/metadata_helper')
require Rails.root.join('app/helpers/items_helper')

# require 'metadata_helper'
require 'fileutils'

class CollectionsController < ApplicationController

  STOMP_CONFIG = YAML.load_file("#{Rails.root.to_s}/config/broker.yml")[Rails.env] unless defined? STOMP_CONFIG

  # Don't bother updating _sign_in_at fields for every API request
  prepend_before_filter :skip_trackable # , only: [:add_items_to_collection, :add_document_to_item]
  before_filter :authenticate_user!, except: [:index, :show]

  #load_and_authorize_resource
  load_resource :only => [:create]
  skip_authorize_resource :only => [:create] # authorise create method with custom permission denied error

  set_tab :collection

  include RequestValidator
  include ItemsHelper

  PER_PAGE_RESULTS = 20
  #
  #
  #
  def index
    respond_to do |format|
      format.html {
        if user_signed_in?
          @my_collections = my_collections
        end

        @collections = collections_by_user_type
      }
      format.json {
        if user_signed_in?
          @collections = my_collections
        end

        # @collections << collections_by_name
        @collections << collections_by_user_type
      }
    end
  end

  # Show collection details according to 3 factors:
  #
  # 1. user type: guest, registered user (owner/non-owner), admin
  # 2. collection status: draft, released, finalised
  # 3. collection private: true, false
  #
  #
  def show

    @collection = Collection.find_by_name(params[:id])

    access_rlt = CollectionsHelper.collection_accessible?(@collection, current_user)

    if access_rlt.nil?
      msg = "Collection does not exist with the given id: #{params[:id]}"
      logger.info "show: #{msg}"
      resource_not_found(Exception.new(msg))
      return
    end

    case access_rlt[:show]
      when 10
        # Need login to proceed.
        msg = "Please log in to access collection '#{params[:id]}'"
        logger.info "show: #{msg}"
        authorization_error(Exception.new(msg))
        return
      when 20
        #   Need draft access permission to proceed.
        msg = "Please contact admin/collection-owner to access draft collection '#{params[:id]}'"
        logger.info "show: #{msg}"
        authorization_error(Exception.new(msg))
        return
      when 30
        #   Need private access permission to proceed.
        msg = "Please accept licence agreement of collection '#{@collection.name}' to proceed."
        logger.info "show: #{msg}"
        redirect_to account_licence_agreements_url, :notice => msg
        return
      when 0
        # you reach here, you can see
        #
        # prepare collection title
        begin
          @collection_title = @collection.collection_properties.select{|p| p.property == MetadataHelper::PFX_TITLE}.first.value
        rescue Exception => e
          logger.error "show: can't retrieve collection title from collection_properties due to [#{e.message}], use collection name instead"
          @collection_title = @collection.name
        end


        @attachment_url = collection_attachments_path(@collection.id)

        respond_to do |format|
          format.html {render :show}
          format.json {}
        end
      else
        #     what can be anything else?
        msg = "unknown access permission found [#{access_rlt[:show]}]"
        logger.error "show: #{msg}"
        internal_error(Exception.new(msg))
        return
    end
  end

  def create
    authorize! :create, @collection,
               :message => "Permission Denied: Your role within the system does not have sufficient privileges to be able to create a collection. Please contact an Alveo administrator."
    collection_metadata = params[:collection_metadata]
    collection_name = params[:name]
    licence_id = params[:licence_id].present? ? params[:licence_id] : nil
    privacy = true
    privacy = (params[:private].to_s.downcase == 'true') unless params[:private].nil?
    owner = User.find_by_authentication_token(params[:api_key])
    begin
      validate_new_collection(collection_metadata, collection_name, licence_id, privacy)
      @success_message = create_collection_core(Collection.sanitise_name(collection_name), collection_metadata, owner, licence_id, privacy)
    rescue ResponseError => e
      respond_with_error(e.message, e.response_code)
      return # Only respond with one error at a time
    end
  end

  #
  # List all collections by user type (guest/collection owner/admin)
  #
  def collections_by_user_type
    if !user_signed_in?
      Collection.only_released_and_finalised.order(:name)
    else
      if current_user.is_superuser?
        Collection.where("owner_id != ?", current_user.id).order(:name)
      else
        (Collection.only_released_and_finalised.where("owner_id != ?", current_user.id).order(:name) + CollectionsHelper.draft_collection_by_user(current_user)).uniq
      end
    end
  end

  #
  # List all collections by name (include collection in collection_list)
  #
  def collections_by_name
    Collection.order(:name)
  end

  # List all current user's collections
  def my_collections
    Collection.where(owner_id: current_user.id)
  end

  def lists_by_name
    CollectionList.order(:name)
  end

  def new
  end

  #
  #
  #
  def add_licence_to_collection
    collection = Collection.find(params[:collection_id])
    licence = Licence.find(params[:licence_id])

    collection.set_licence(licence)

    flash[:notice] = "Successfully added licence to #{collection.name}"
    redirect_to licences_path(:hide => (params[:hide] == true.to_s) ? "t" : "f")
  end

  #
  #
  #
  def change_collection_privacy
    collection = Collection.find(params[:id])
    private = params[:privacy]
    collection.set_privacy(private)
    if private == "false"
      UserLicenceRequest.where(:request_id => collection.id.to_s).destroy_all
    end
    private == "true" ? state = "requiring approval" : state = "not requiring approval"
    flash[:notice] = "#{collection.name} has been successfully marked as #{state}"
    redirect_to licences_path
  end

  #
  #
  #
  def revoke_access
    collection = Collection.find(params[:id])
    UserLicenceRequest.where(:request_id => collection.id.to_s).destroy_all if collection.private?
    UserLicenceAgreement.where(name: collection.name, collection_type: 'collection').destroy_all
    flash[:notice] = "All access to #{collection.name} has been successfully revoked"
    redirect_to licences_path
  end

  def web_create_collection
    authorize! :web_create_collection, Collection
    # Expose public licences and user created licences

    @collection_name = params[:collection_name]
    @collection_title = params[:collection_title]
    @collection_alveo_owner = current_user
    @collection_legal_owner = params[:collection_legal_owner]
    @collection_text = params[:collection_text]
    @collection_abstract = params[:collection_abstract].nil? ? "" : params[:collection_abstract].gsub(/\r\n/, ' ').gsub(/"/, '\"')
    @approval_required = params[:approval_required]
    @approval_required = 'private' if request.get?
    @licence_id = params[:licence_id]
    @additional_metadata = zip_additional_metadata(params[:additional_key], params[:additional_value])

    @collection_status_options = [
      ['DRAFT - only you can see your own draft collection', 'DRAFT'],
      ['RELEASED - you can still update released collection', 'RELEASED'],
      ['FINALISED - can NOT update anymore', 'FINALISED']]

    # mandatory params
    @collection_language = params[:collection_language]
    @collection_language = 'eng - English' if @collection_language.nil?
    @collection_languages = Language.all.collect {|l| ["#{l.code} - #{l.name}", "#{l.code} - #{l.name}"]}
    #
    #
    @collection_creation_date = params[:collection_creation_date]
    @collection_creator = params[:collection_creator]

    # no default olac subject
    @olac_subject = params[:olac_subject].nil? ? "" : params[:olac_subject]

    @collection_licences = licences

    if request.get?

      @collection_name = nil
      @collection_title = nil
      @collection_creation_date = nil
      @collection_creator = nil
      @collection_legal_owner = nil
      @collection_abstract = ""
      @collection_text = nil
      @approval_required = 'public'

      #   load content only for Get
      @olac_subject_options = MetadataHelper::OLAC_LINGUISTIC_SUBJECT_HASH

      @additional_metadata = {}
      @additional_metadata_options = metadata_names_mapping

      @collection_creator = current_user.full_name + "(#{current_user.email})"
      @collection_alveo_owner = current_user
      @collection_legal_owner = current_user.full_name

      if current_user.is_superuser?
        @approved_owners = approved_collection_owners
      end

    end

    if request.post?
      begin
        validate_required_web_fields(
          params,
          {
            :collection_name => 'collection name'
          }
        )

        # Validate and sanitise additional metadata fields
        additional_metadata = validate_collection_additional_metadata(params)

        # retrieve valid licence
        lic = licence(@licence_id)

        # Construct collection Json-ld
        json_ld = {
          '@context' => JsonLdHelper.default_context,
          '@type' => 'dcmitype:Collection',
          MetadataHelper::CREATOR.to_s => @collection_creator,
          MetadataHelper::LOC_OWNER.to_s => @collection_legal_owner,
          MetadataHelper::LICENCE.to_s => (lic ? lic.name : ""),
          MetadataHelper::OLAC_SUBJECT.to_s => @olac_subject,
          MetadataHelper::ABSTRACT.to_s => @collection_abstract
        }

        # json_ld.merge!(olac_metadata) { |key, val1, val2| val1 }

        json_ld.merge!(additional_metadata) {|key, val1, val2| val1}

        # Ingest new collection
        name = Collection.sanitise_name(params[:collection_name])
        msg = create_collection_core(
          name,
          json_ld,
          current_user,
          (lic ? lic.id : nil),
          @approval_required == 'private',
          @collection_text)

        redirect_to collection_path(id: name), notice: msg
      rescue ResponseError => e
        flash[:error] = e.message
      end
    end
  end

  def add_items_to_collection
    # referenced documents (HCSVLAB-1019) are already handled by the look_for_documents part of the item ingest
    logger.debug "collectios#add_items_to_collection"

    begin
      request_params = cleanse_params(params)
      collection = validate_collection(request_params[:id], request_params[:api_key])
      # ToDo: sanitise each item name (dc:identifier) once the new JSON-LD format is completed
      validate_add_items_request(collection, collection.corpus_dir, request_params[:items], request_params[:file])
      request_params[:items].each do |item_json|
        update_ids_in_jsonld(item_json["metadata"], collection)
      end
      uploaded_files = process_uploaded_files(collection.corpus_dir, collection.name, request_params[:file])
      processed_items = process_items(collection.name, collection.corpus_dir, request_params, uploaded_files)
      @success_message = add_item_core(collection, processed_items[:successes])
    rescue ResponseError => e
      respond_with_error(e.message, e.response_code)
      return # Only respond with one error at a time
    end
  end

  def web_add_item
    @collection = Collection.find_by_name(params[:id])
    authorize! :web_add_item, @collection
    @item_name = params[:item_name]
    @item_title = params[:item_title]
    @additional_metadata = zip_additional_metadata(params[:additional_key], params[:additional_value])
    if request.post?
      begin
        # Raise an exception if required fields are empty
        validate_required_web_fields(params, {:item_name => 'item name', :item_title => 'item title'})

        # Raise an exception if item is not unique in the collection
        item_name = validate_item_name_unique(@collection, Item.sanitise_name(params[:item_name]))

        msg = add_item(params, item_name, @collection)
        msg = "Created new item: #{msg.first}" # Format the item creation message

        redirect_to catalog_path(collection: @collection.name, itemId: item_name), notice: msg
      rescue ResponseError => e
        flash[:error] = e.message
      end
    end
  end

  #
  # POST "catalog/:collectionId/:itemId"
  #
  def add_document_to_item
    begin
      collection = validate_collection(params[:collectionId], params[:api_key])
      item = validate_item_exists(collection, params[:itemId])
      doc_metadata = parse_str_to_json(params[:metadata], 'JSON document metadata is ill-formatted')

      logger.debug "add_document_to_item: params[:metadata]=#{params[:metadata]}, doc_metadata[#{doc_metadata}]"

      doc_content = params[:document_content]
      uploaded_file = params[:file]
      uploaded_file = uploaded_file.first if uploaded_file.is_a? Array
      doc_filename = MetadataHelper.get_dc_identifier(doc_metadata) # the document filename is the document id
      doc_metadata = format_and_validate_add_document_request(collection.corpus_dir, collection, item, doc_metadata, doc_filename, doc_content, uploaded_file)
      @success_message = CollectionsHelper.add_document_core(collection, item, doc_metadata, doc_filename)
    rescue ResponseError => e
      respond_with_error(e.message, e.response_code)
      return # Only respond with one error at a time
    end
  end

  def web_add_document
    collection = Collection.find_by_name(params[:collection])
    authorize! :web_add_document, collection

    @language = params[:language]
    @language = 'eng - English' if @language.nil?
    @languages = Language.all.collect {|l| ["#{l.code} - #{l.name}", "#{l.code} - #{l.name}"]}
    @additional_metadata = zip_additional_metadata(params[:additional_key], params[:additional_value])
    if request.post?
      item = Item.find_by_handle(Item.format_handle(collection.name, params[:itemId]))
      uploaded_file = params[:document_file]
      begin
        validate_required_web_fields(params, {:document_file => 'document file', :language => 'language'})
        validate_new_document_file(collection.corpus_dir, uploaded_file.original_filename, collection)
        additional_metadata = validate_document_additional_metadata(params)
        uploaded_file_path = upload_document_using_multipart(collection.corpus_dir, uploaded_file.original_filename, uploaded_file, collection.name)
        json_ld = construct_document_json_ld(collection, item, params[:language], uploaded_file_path, additional_metadata)
        msg = CollectionsHelper.add_document_core(collection, item, json_ld, uploaded_file_path)
        redirect_to catalog_path(collection: collection.name, itemId: item.get_name), notice: msg
      rescue ResponseError => e
        flash[:error] = e.message
      end
    end
  end

  def delete_item_from_collection
    begin
      collection = validate_collection(params[:collectionId], params[:api_key])
      item = validate_item_exists(collection, params[:itemId])
      @success_message = delete_item_core(item)
    rescue ResponseError => e
      respond_with_error(e.message, e.response_code)
      return # Only respond with one error at a time
    end
  end

  def delete_item_via_web_app
    authorize! :delete_item_via_web_app, Collection.find_by_name(params[:collectionId])
    item = Item.find_by_handle(Item.format_handle(params[:collectionId], params[:itemId]))
    begin
      msg = delete_item_core(item)
      redirect_to catalog_index_path, notice: msg
    rescue ResponseError => e
      flash[:error] = e.message
    end
  end

  def delete_item_core(item)
    # check collection status
    if item.collection.is_finalised?
      return "Cannot modify finalised collection or its item/document."
    end

    remove_item(item, item.collection)
    "Deleted the item #{item.get_name} (and its documents) from collection #{item.collection.name}"
  end

  def delete_document_from_item
    begin
      collection = validate_collection(params[:collectionId], params[:api_key])
      item = validate_item_exists(collection, params[:itemId])
      document = validate_document_exists(item, params[:filename])
      @success_message = CollectionHelper.delete_document_core(collection, item, document)
    rescue ResponseError => e
      respond_with_error(e.message, e.response_code)
      return # Only respond with one error at a time
    end
  end

  def delete_document_via_web_app
    authorize! :delete_document_via_web_app, Collection.find_by_name(params[:collectionId])
    begin
      item = Item.find_by_handle(Item.format_handle(params[:collectionId], params[:itemId]))
      collection = item.collection
      document = item.documents.find_by_file_name(params[:filename])
      msg = CollectionsHelper.delete_document_core(collection, item, document)
      redirect_to catalog_path(params[:collectionId], params[:itemId]), notice: msg
    rescue ResponseError => e
      Rails.logger.error e.message
      flash[:error] = e.message
    end
  end

  def edit_collection
    authorize! :edit_collection, Collection

    @collection = Collection.find_by_name(params[:id])

    @collection_alveo_owner = @collection.owner

    access_rlt = CollectionsHelper.collection_accessible?(@collection, current_user)

    if access_rlt.nil?
      msg = "Collection does not exist with the given id: #{params[:id]}"
      logger.info "show: #{msg}"
      resource_not_found(Exception.new(msg))
      return
    end

    case access_rlt[:edit]
      when 10
        # Need login to proceed.
        msg = "Please log in to access collection '#{params[:id]}'"
        logger.info "edit: #{msg}"
        authorization_error(Exception.new(msg))
        return
      when 20
        #   Need draft access permission to proceed.
        msg = "Please contact admin/collection-owner to access draft collection '#{params[:id]}'"
        logger.info "edit: #{msg}"
        authorization_error(Exception.new(msg))
        return
      when 30
        #   Need private access permission to proceed.
        msg = "Please accept licence agreement of collection '#{@collection.name}' to proceed."
        logger.info "edit: #{msg}"
        redirect_to account_licence_agreements_url, :notice => msg
        return
      when 40
        # Need admin permission to proceed.
        if !current_user.is_superuser?
          msg = "Please contact admin to proceed."
          logger.info "edit: non-admin can't edit finalised collection"
          redirect_to root_url, :notice => msg
          return
        end
      when 0
        # you reach here, you can go on to edit
      else
        #     what can be anything else?
        msg = "unknown access permission found [#{access_rlt[:edit]}]"
        logger.error "edit: #{msg}"
        internal_error(Exception.new(msg))
        return
    end

    @collection_licences = licences

    @approval_required = (@collection.private ? 'private' : 'public')

    # mandatory collection properties
    properties = {}
    exclude_prop = ['@context', '@type', '@id', MetadataHelper::PFX_LICENCE]
    @collection.collection_properties.each do |prop|
      # use array to store multi value
      unless exclude_prop.include?(prop.property)
        if properties.key?(prop.property)
          #   multi value?
          value = properties[prop.property]
          if value.is_a? (Array)
            properties[prop.property] = (value << prop.value)
          else
            properties[prop.property] = (Array.new([value]) << prop.value)
          end
        else
          properties[prop.property] = prop.value
        end
      end
    end

    @collection_title = properties.delete(MetadataHelper::PFX_TITLE)
    @collection_legal_owner = properties.delete(MetadataHelper::PFX_LEGAL_OWNER)
    @collection_language = properties.delete(MetadataHelper::PFX_LANGUAGE)
    @collection_languages = Language.all.map {|l| ["#{l.code} - #{l.name}", "#{l.code} - #{l.name}"]}.to_h

    if @collection_language.nil?
      @collection_language = 'eng - English'
    else
      unless @collection_languages.key?(@collection_language)
        #   no such lang, need to append
        @collection_languages[@collection_language] = @collection_language
      end
    end

    @collection_creation_date = properties.delete(MetadataHelper::PFX_CREATION_DATE)
    @collection_creator = properties.delete(MetadataHelper::PFX_CREATOR)
    @collection_abstract = properties.delete(MetadataHelper::PFX_ABSTRACT)

    @collection_status_options = [
      ['DRAFT - only you can see your own draft collection', 'DRAFT'],
      ['RELEASED - you can still update released collection', 'RELEASED'],
      ['FINALISED - can NOT update anymore', 'FINALISED']]

    if current_user.is_superuser?
      @approved_owners = approved_collection_owners
    end

    # olac subject
    @olac_subject = properties.delete(MetadataHelper::PFX_OLAC_SUBJECT)
    @olac_subject_options = MetadataHelper::OLAC_LINGUISTIC_SUBJECT_HASH

    # additional metadata
    # OK, all basic metadata gone, so only additional metadata left
    @additional_metadata = properties
    @additional_metadata_options = metadata_names_mapping

    #   attachment url
    @attachment = Attachment.new({collection_id: @collection.id})
    @attachment_url = new_attachment_url(@collection)
  end

  def licences
    licence_table = Licence.arel_table
    Licence.where(licence_table[:private].eq(false).or(licence_table[:owner_id].eq(current_user.id)))
  end

  #
  # Update collection
  #
  def update_collection
    authorize! :update_collection, Collection

    name = Collection.sanitise_name(params[:id])

    begin

      lic = licence(params[:licence_id])

      # logger.debug "olac_metadata=#{olac_metadata}"

      # Validate and sanitise additional metadata fields
      additional_metadata = validate_collection_additional_metadata(params)
      logger.debug "update_collection: additional_metadata=#{additional_metadata}"

      # Construct collection Json-ld
      json_ld = {
        '@context' => JsonLdHelper.default_context,
        '@type' => 'dcmitype:Collection',
        MetadataHelper::TITLE.to_s => params[:collection_title].nil? ? '' : params[:collection_title],
        MetadataHelper::LANGUAGE.to_s => params[:collection_language].nil? ? '' : params[:collection_language],
        MetadataHelper::CREATED.to_s => params[:collection_creation_date].nil? ? '' : params[:collection_creation_date],
        MetadataHelper::CREATOR.to_s => params[:collection_creator].nil? ? '' : params[:collection_creator],
        MetadataHelper::LOC_OWNER.to_s => params[:collection_legal_owner].nil? ? '' : params[:collection_legal_owner],
        MetadataHelper::OLAC_SUBJECT.to_s => params[:olac_subject].nil? ? '' : params[:olac_subject],
        MetadataHelper::LICENCE.to_s => lic.name,
        MetadataHelper::ABSTRACT.to_s => params[:collection_abstract].nil? ? '' : params[:collection_abstract]
      }

      # json_ld.merge!(olac_metadata) { |key, val1, val2| val1 }

      json_ld.merge!(additional_metadata) {|key, val1, val2| val1}

      # Ingest new collection
      # name = Collection.sanitise_name(params[:collection_name])

      # check owner
      owner = current_user
      if !params[:collection_alveo_owner].nil?
        owner = User.find_by_id(params[:collection_alveo_owner])
        if owner.nil?
          msg = "Can't find collection owner by '#{params[:collection_alveo_owner]}'"
          redirect_to collection_path(id: name), notice: msg

          return
        end
      end

      msg = create_collection_core(name, json_ld, owner, lic.id, params[:approval_required] == 'private', params[:collection_text], params[:collection_status])
      redirect_to collection_path(id: name), notice: msg
    rescue ResponseError => e
      flash[:error] = e.message
      logger.error "update_collection: collection name: #{name}, #{e.message}"

      redirect_to edit_collection_path(id: name)
    end

  end

  def delete_collection
    authorize! :delete_collection, Collection

    collection = Collection.find_by_name(params[:id])

    if collection.nil?
      raise ResponseError.new(404), "A collection with the name '#{params[:id]}' not exist."
    end

    name = collection.name
    corpus_dir = collection.corpus_dir

    # TODO: delete sesame & solr

    unless collection.destroy.nil?
      # unless collection.nil?
      #   delete directory as well
      # corpus_dir = MetadataHelper::corpus_dir_by_name(name)
      logger.debug "remove directory #{corpus_dir}"
      FileUtils.remove_dir(corpus_dir, true)

      flash[:notice] = "Collection with the name '#{name}' has been removed successfully."
      redirect_to :collections
    end

  end

  def update_item
    begin
      collection = validate_collection(params[:collectionId], params[:api_key])
      item = validate_item_exists(collection, params[:itemId])
      validate_jsonld(params[:metadata])
      new_metadata = format_update_item_metadata(item, params[:metadata])
      update_item_in_sesame(new_metadata, collection)
      update_item_in_solr(item)
      @success_message = "Updated item #{item.get_name} in collection #{collection.name}"
    rescue ResponseError => e
      respond_with_error(e.message, e.response_code)
      return # Only respond with one error at a time
    end
  end

  #
  # Update collection's access permission to specific user (so far only implemented for "draft collection read permission")
  #
  def update_permission
    collection = Collection.find_by_id(params[:id])

    msg = ""

    if collection.nil?
      msg = "Collection does not exist with the given id: #{params[:id]}"
      logger.info "update_permission: #{msg}"
      resource_not_found(Exception.new(msg))
      return
    end

    email_list = params[:email_list]
    req_type = params[:request_type]

    if !email_list.nil?
      email_list = email_list.split("\r\n")
    end

    logger.debug "email_list[#{email_list}]"

    ActiveRecord::Base.transaction do
      UserLicenceRequest.destroy_all(request_id: collection.id.to_s, request_type: req_type)

      email_list.each do |email|
        user = User.find_by_email(email)

        # check user exists
        if user.nil?
          msg = "User does not exist with the given email: #{email}"
          logger.info "update_permission: #{msg}"
          redirect_to user_licence_requests_path, notice: msg
          return
        end

        if !UserLicenceRequest.exists?(request_id: collection.id.to_s, request_type: req_type, user_id: user.id)
          UserLicenceRequest.create!(
            request_id: collection.id,
            request_type: req_type,
            approved: true,
            user_id: user.id,
            owner_id: collection.owner.id)
        end
      end
    end

    msg = "Access permission of collection [#{collection.name}] updated."

    logger.debug "update_permission: #{msg}"

    redirect_to user_licence_requests_path, notice: msg

    return

  end

  # ---------------------------
  private

  #
  # Creates the model for blacklight pagination.
  #
  #def create_pagination_structure(params)
  #  start = (params[:page].nil?)? 0 : params[:page].to_i-1
  #  total = @collections.length
  #
  #  per_page = (params[:per_page].nil?)? PER_PAGE_RESULTS : params[:per_page].to_i
  #  per_page = PER_PAGE_RESULTS if per_page < 1
  #
  #  current_page = (start / per_page).ceil + 1
  #  num_pages = (total / per_page.to_f).ceil
  #
  #  total_count = total
  #
  #  @collections = @collections[(current_page-1)*per_page..current_page*per_page-1]
  #
  #  start_num = start + 1
  #  end_num = start_num + @collections.length - 1
  #
  #  @paging = OpenStruct.new(:start => start_num,
  #                           :end => end_num,
  #                           :per_page => per_page,
  #                           :current_page => current_page,
  #                           :num_pages => num_pages,
  #                           :limit_value => per_page, # backwards compatibility
  #                           :total_count => total_count,
  #                           :first_page? => current_page > 1,
  #                           :last_page? => current_page < num_pages
  #  )
  #end

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
  def create_metadata_and_manifest(collection_name, collection_rdf, collection_manifest = {"collection_name" => collection_name, "files" => {}})

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

  # Processes the metadata for each item in the supplied request parameters
  # Returns a hash containing :successes and :failures of processed items
  def process_items(collection_name, corpus_dir, request_params, uploaded_files = [])
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
        end
      end
    end
    raise 'Could not obtain document URI from Sesame' if document_uri.nil?
    document_uri
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
  # def delete_file(file_path)
  #   begin
  #     File.delete(file_path)
  #   rescue => e
  #     Rails.logger.error e.inspect
  #     false
  #   end
  # end

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
      part_of_exists = false
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


  #
  # Core functionality common to creating a collection
  #
  def create_collection_core(name, metadata, owner, licence_id = nil, private = true, text = '', status = 'RELEASED')
    logger.debug "create_collection_core: start - name[#{name}], metadata[#{metadata}], owner[#{owner}], licence_id[#{licence_id}], private[#{private}], text[#{text}], status[#{status}]"

    metadata = MetadataHelper::update_jsonld_collection_id(
      MetadataHelper::not_empty_collection_metadata!(name, current_user.full_name, metadata), name)
    uri = metadata['@id']
    # KL: if collection exist, update
    # if Collection.find_by_uri(uri).present? # ingest skips collections with non-unique uri
    #   raise ResponseError.new(400), "A collection with the name '#{name}' already exists"

    logger.debug "create_collection_core: uri[#{uri}]"

    collection = Collection.find_by_uri(uri)
    unless collection.nil?
      # existing collection, update
      collection.name = name
      collection.uri = uri
      collection.owner = owner
      collection.licence_id = licence_id
      collection.private = private
      collection.text = text
      collection.status = status
      collection.save

      MetadataHelper::update_collection_metadata_from_json(name, metadata)

      "Collection '#{name}' (#{uri}) updated"

    else
      if licence_id.present? and Licence.find_by_id(licence_id).nil?
        raise ResponseError.new(400), "Licence with id #{licence_id} does not exist"
      end

      MetadataHelper.create_manifest(name)

      MetadataHelper.update_collection_metadata_from_json(name, metadata)

      # corpus_dir = MetadataHelper::corpus_dir_by_name(name)

      # check_and_create_collection(name, corpus_dir, metadata)

      populate_triple_store(nil, name, nil)

      collection = Collection.find_by_name(name)

      collection.owner = owner
      collection.licence_id = licence_id
      collection.status = status
      collection.private = private

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
        MetadataHelper::ABSTRACT.to_s]

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
  def validate_additional_metadata(additional_metadata, protected_field_keys, metadata_type = "additional")
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
    {'@context' => JsonLdHelper.default_context, '@graph' => [item_metadata]}
  end

  #
  # Constructs Json-ld for a new document
  #
  def construct_document_json_ld(collection, item, language, document_file, metadata)
    JsonLdHelper.construct_document_json_ld(collection, item, language, document_file, metadata)
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

  def skip_trackable
    request.env['devise.skip_trackable'] = true
  end

  # collection owner = superuser + data_owner
  # select options, "owner full name" => "owner id"
  def approved_collection_owners
    (User.approved_data_owners + User.approved_superusers).map{|o| ["#{o.full_name} (#{o.email})", "#{o.id}"]}.sort!.to_h
  end

end
