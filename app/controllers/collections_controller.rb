require "#{Rails.root}/lib/tasks/fedora_helper.rb"
require 'fileutils'

class CollectionsController < ApplicationController
  before_filter :authenticate_user!
  #load_and_authorize_resource

  set_tab :collection

  PER_PAGE_RESULTS = 20
  NEW_COLLECTION_DIR = File.join(Rails.root.to_s, 'data', 'collections', 'api')
  #
  #
  #
  def index
    @collections = collections_by_name
    @collection_lists = lists_by_name
    respond_to do |format|
      format.html
      format.json
    end
  end

  #
  #
  #
  def show
    @collections = collections_by_name
    @collection_lists = lists_by_name

    @collection = Collection.find_by_name(params[:id])
    respond_to do |format|
      if @collection.nil? or @collection.name.nil?
        format.html { 
            flash[:error] = "Collection does not exist with the given id"
            redirect_to collections_path }
        format.json { render :json => {:error => "not-found"}.to_json, :status => 404 }
      else
        format.html { render :index }
        format.json {}
      end
    end
  end

  def create
    if request.format == 'json' and request.post?
      collection_name = params[:name]
      if (!collection_name.nil? and !collection_name.blank? and !(collection_name.length > 255) and !(params[:collection_metadata].nil?))
        # Parse JSON-LD formatted collection metadata and convert to RDF
        json_md = params[:collection_metadata]
        graph = RDF::Graph.new << JSON::LD::API.toRdf(json_md)
        collection_rdf = graph.dump(:ttl, prefixes: {foaf: "http://xmlns.com/foaf/0.1/"})
        collection_uri = graph.statements.first.subject.to_s
        if !Collection.find_by_uri(collection_uri).present?  # ingest skips collections with non-unique name or uri
          # write metadata and manifest file for ingest
          collection_dir = NEW_COLLECTION_DIR
          FileUtils.mkdir_p(collection_dir) unless File.directory?(collection_dir)
          metadata_file_path = File.join(collection_dir,  collection_name + '.n3')
          corpus_dir = File.join(collection_dir, collection_name)
          FileUtils.mkdir_p(corpus_dir) unless File.directory?(corpus_dir)
          manifest_file_path = File.join(corpus_dir, MANIFEST_FILE_NAME)
          begin
            metadata_file = File.open(metadata_file_path, 'w')
            metadata_file.puts collection_rdf
          ensure
            metadata_file.close if !metadata_file.nil?
          end
          begin
            manifest_hash = {"collection_name" => collection_name, "files" => {}}
            manifest_file = File.open(manifest_file_path, 'w')
            manifest_file.puts(manifest_hash.to_json)
          ensure
            manifest_file.close if !manifest_file.nil?
          end

          ingest_corpus(corpus_dir)
        else
          err_message = "Collection #{collection_name} (#{collection_uri}) already exists in the system - skipping"
          respond_to do |format|
            format.any { render :json => {:error => err_message}.to_json, :status => 400 }
          end
        end
      else
        invalid_name = collection_name.nil? or collection_name.blank? or collection_name.length > 255
        invalid_metadata = params[:collection_metadata].nil?
        err_message = "name parameter" if invalid_name
        err_message = "metadata parameter" if invalid_metadata
        err_message = "name and metadata" if invalid_name and invalid_metadata
        err_message << " not found" if !err_message.nil?
        respond_to do |format|
          format.any { render :json => {:error => err_message}.to_json, :status => 400 }
        end
      end
    else
      #TODO handle case when a non JSON POST request is sent
    end
  end

  def collections_by_name
    Collection.not_in_list.order(:name)
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
    redirect_to licences_path(:hide=>(params[:hide] == true.to_s)?"t":"f")
  end

  #
  #
  #
  def change_collection_privacy
    collection = Collection.find(params[:id])
    private = params[:privacy]
    collection.set_privacy(private)
    if private=="false"
      UserLicenceRequest.where(:request_id => collection.id.to_s).destroy_all
    end
    private=="true" ? state="requiring approval" : state="not requiring approval"
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

end
