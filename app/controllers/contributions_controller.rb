require Rails.root.join('lib/api/response_error')
require Rails.root.join('lib/api/request_validator')


class ContributionsController < ApplicationController

  before_filter :authenticate_user!, :except => [:index]

  # GET "contrib/"
  def index
    @own_contributions = own_contributions
    @shared_contributions = shared_contributions

    begin
      respond_to do |format|
        format.html
        format.json
      end
    rescue Exception => e
      logger.error "index: #{e.message}"
      internal_error(e)
    end


  end

  # GET "/contrib/new"
  def new
    # authorize! :new, Contribution

    @contribution_name = nil
    @contribution_title = nil
    @contribution_abstract = nil
    @contribution_text = nil

    # load collection names for select options
    @contribution_collections = Collection.order(:name).pluck(:name)

  end

  # POST "contrib/"
  def create

    contribution_name = @contribution_title = params[:contribution_name]
    contribution_collection = params[:contribution_collection]
    contribution_text = params[:contribution_text]
    contribution_abstract = params[:contribution_abstract]

    begin
      validate_required_web_fields(
        params,
        {
          :contribution_name => 'contribution name',
          :contribution_collection => 'contribution collection'
        }
      )

      # check duplicated
      contrib = Contribution.find_by_name(contribution_name)
      if !contrib.nil?
        #   contrib with same name already exists
        msg = "Contribution name '#{contribution_name}' already been taken."
        logger.warn "create: #{msg}"
        conflict_error(Exception.new(msg))
        return
      end

      attr = {
        :name => contribution_name,
        :owner => current_user,
        :collection => contribution_collection,
        :description => contribution_text,
        :abstract => contribution_abstract
      }

      msg, contrib_id = ContributionsHelper.upsert_contribution_core(attr)

      # create contrib directory
      FileUtils.makedirs(File.join(APP_CONFIG["contrib_dir"], contribution_collection, contrib_id.to_s))

      respond_to do |format|
        format.html {
          redirect_to contrib_show_path(id: contrib_id), notice: msg
        }
        format.json {
          redirect_to contrib_show_path(id: contrib_id, format: :json)
        }
      end

    rescue Exception => e
      respond_to do |format|
        format.html {
          flash[:error] = e.message
          redirect_to contrib_new_path
        }
        format.json {
          render :json => {:error => "#{e.message}"}.to_json, :status => 422
        }
      end
    end
  end

  # GET "contrib/:id"
  def show

    @contribution = Contribution.find_by_id(params[:id])

    if @contribution.nil?
      msg = "Contribution does not exist with the given id: #{params[:id]}"
      logger.warn "show: #{msg}"
      resource_not_found(Exception.new(msg), contrib_index_url)
      return
    else
      # load metadata
      metadata = ContributionsHelper.load_contribution_metadata(@contribution.name)

      @contribution_metadata = {
        :title => @contribution.name,
        :collection => collection_url(@contribution.collection.name),
        :creator => @contribution.owner.full_name,
        :created => @contribution.created_at,
        :abstract => metadata["dcterms:abstract"].to_json
      }

      # extract files type
      @doc_filetypes = {}
      file_hash = ContributionsHelper.all_related_files(@contribution)

      file_hash.each do |handle, value|
        files = file_hash[handle][:files]
        files.each do |f|
          ext = File.extname(f)
          # if file has no ext, ext is ""
          # if user export file type "no extension", wildcard is '*', then download all files
          @doc_filetypes[ext] = (@doc_filetypes[ext].nil? ? 1 : @doc_filetypes[ext]+1)
        end
      end

      # load mapping data
      @contribution_mapping = ContributionsHelper.load_contribution_mapping(@contribution)

      respond_to do |format|
        format.html {render :show}
        format.json
      end
    end

  end

  # GET "contrib/:id/edit"
  def edit
    @contribution = Contribution.find_by_id(params[:id])
    @contribution_metadata = ContributionsHelper.load_contribution_metadata(@contribution.name)

    # collect extra info for add_document_to_item
    metadata = ""
    @contribution_mapping = ContributionsHelper.load_contribution_mapping(@contribution)
  end

  # GET "contrib/:id/preview"
  #
  # phrase 0: Import from Zip
  # phrase 1: Review Import
  #
  def preview
    @contribution = Contribution.find_by_id(params[:id])
    @contribution_metadata = ContributionsHelper.load_contribution_metadata(@contribution.name)
    @preview_result = []
    @phrase = "0"
    if @sep.nil?
      @sep = {:type => 'delimiter', :delimiter => "-", :field => "1"}
    end

  end

  #
  # POST "contrib/:id/import"
  #
  def import

    contrib = Contribution.find_by_id(params[:id])

    if contrib.nil?
      msg = "Contribution does not exist with the given id: #{params[:id]}"
      logger.warn "import: #{msg}"
      resource_not_found(Exception.new(msg), contrib_index_url)
      return
    end

    zip_file = params[:file] #  ActionDispatch::Http::UploadedFile
    sep = params[:sep]
    case sep
      when 'delimiter'
        @sep = {:type => 'delimiter',
                :delimiter => params[:delimiter].nil? ? '-' : params[:delimiter],
                :field => params[:field].nil? ? 1 : params[:field].to_i}
      when 'offset'
        @sep = {:type => 'offset',
                :offset => params[:offset].nil? ? -1 : params[:offset].to_i}
      when 'item'
        @sep = {:type => 'item'}
      when 'doc'
        @sep = {:type => 'doc'}
    end

    if !zip_file.nil?
      # cp file to contrib dir (overwrite) for later use
      logger.debug "import: zip_file[#{zip_file.inspect}]"
      contrib_zip_file = ContributionsHelper.contribution_import_zip_file(contrib)
      FileUtils.mkdir_p(ContributionsHelper.contribution_dir(contrib))
      FileUtils.cp(zip_file.tempfile, contrib_zip_file)
    else
      #   no uploaded file found
      logger.warn "import: no uploaded file found!"
    end

    is_preview = params[:preview]

    if !is_preview.nil?
      #   preview mode
      # load preview
      @contribution = contrib
      @contribution_metadata = ContributionsHelper.load_contribution_metadata(contrib.name)
      @preview_result = ContributionsHelper.preview_import(contrib, @sep)
      @phrase = "1"

      render "preview"
    else
      #   import mode
      message = ContributionsHelper.import(contrib, @sep)

      respond_to do |format|
        format.html {
          flash[:notice] = "#{message}"
          redirect_to contrib_show_url(params[:id])
        }
        format.json {
          if message.start_with?("OK")
            #   success
            redirect_to contrib_show_path(id: contrib.id, format: :json)
          else
            render :json => {:error => "#{message}"}.to_json, :status => 422
          end

        }
      end

    end

  end

  #
  # PUT "contrib/:id"
  #
  def update
    contrib = Contribution.find_by_id(params[:id])

    if contrib.nil?
      msg = "Contribution does not exist with the given id: #{params[:id]}"
      logger.warn "update: #{msg}"
      resource_not_found(Exception.new(msg), contrib_index_url)
      return
    end

    # only update name, abstract and description
    contribution_name = params[:contribution_name]
    contribution_text = params[:contribution_text]
    contribution_abstract = params[:contribution_abstract]

    begin
      # check duplicated name
      if (contribution_name != contrib.name) && (!Contribution.find_by_name(contribution_name).nil?)
        # conflict with existing name
        msg = "Contribution name ' #{contribution_name}' already been taken."
        logger.warn "update: #{msg}"
        conflict_error(Exception.new(msg), contrib_edit_url)
        return
      end

      attr = {
        # basic part
        :id => contrib.id,
        :name => contribution_name,
        :description => contribution_text,
        :abstract => contribution_abstract
      }

      msg, contrib_id = ContributionsHelper.upsert_contribution_core(attr)

      respond_to do |format|
        format.html {
          redirect_to contrib_show_url(id: contrib_id), notice: msg
        }
        format.json {
          redirect_to contrib_show_url(id: contrib_id, format: :json)
        }
      end

    rescue Exception => e
      respond_to do |format|
        format.html {
          flash[:error] = e.message
          redirect_to contrib_show_url(id: contrib.id)
        }
        format.json {
          render :json => {:error => "#{e.message}"}.to_json, :status => 500
        }
      end

    end

  end

  # DELETE "contrib/:id"
  def destroy
    contrib = Contribution.find_by_id(params[:id])

    if contrib.nil?
      msg = "Contribution does not exist with the given id: #{params[:id]}"
      logger.warn "destroy: #{msg}"
      resource_not_found(Exception.new(msg), contrib_index_url)
      return
    end

    if current_user.is_superuser? || ContributionsHelper.is_owner?(current_user, contrib)
      name = contrib.name

      rlt_h = ContributionsHelper.delete_contribution(contrib)
      if rlt_h[:message].nil?
        msg = "Contribution [#{name}] has been removed successfully. #{rlt_h[:document_count]} document(s) removed."
        logger.info "destroy: #{msg}"

        respond_to do |format|
          format.html {
            flash[:notice] = msg
            redirect_to :contrib_index
          }
          format.json {
            render :json => {:success => "#{msg}"}, :status => 200
          }
        end
      else
        msg = "Contribution [#{name}] remove failed: #{rlt_h[:message]}"
        logger.info "destroy: #{msg}"

        respond_to do |format|
          format.html {
            flash[:notice] = msg
            redirect_to :contrib_index
          }
          format.json {
            render :json => {:error => "#{msg}"}, :status => 200
          }
        end
      end
    else
      msg = "Only owner or admin can delete contribution."
      logger.info "destroy: #{msg}"

      respond_to do |format|
        format.html {
          flash[:notice] = msg
          redirect_to :contrib_index
        }
        format.json {
          render :json => {:error => "#{msg}"}, :status => 403
        }
      end
    end
  end

  #
  # GET "contrib/(:id).zip"
  #
  # Returns {}contribution.name}.zip
  #
  def export
    id = params[:id]
    wildcard = params[:wildcard]
    if !params[:doc_filter].blank?
      wildcard = params[:doc_filter].join(',')
    end
    contrib = Contribution.find_by_id(id)

    if contrib.nil?
      msg = "Contribution does not exist with the given id: #{params[:id]}"
      logger.warn "export: #{msg}"
      resource_not_found(Exception.new(msg), contrib_index_url)
      return
    end

    begin
      zip_path = ContributionsHelper.export_as_zip(contrib, wildcard)

      send_file zip_path, :type => 'application/zip',
                :disposition => 'attachment',
                :filename => "#{contrib.name}.zip"
    rescue Exception => e
      msg = "contribution export failed: #{e.message}"
      logger.error "export: #{msg}"

      respond_to do |format|
        format.html {
          flash[:error] = msg
          redirect_to contrib_show_url(id)
        }
        format.json {
          render :json => {:error => "#{msg}"}, :status => 422
        }
        format.zip {
          flash[:error] = msg
          redirect_to contrib_show_url(id)
        }
      end
    end

  end

  # user's own contributions
  def own_contributions
    rlt = []
    if current_user.present?
      rlt = Contribution.where(:owner_id => current_user.id).order(:name)
    end

    rlt.each do |contrib|
      # replace description with abstract for display purpose
      # contrib.description = MetadataHelper::load_metadata_from_contribution(contrib.name)[:abstract]
      metadata = ContributionsHelper.load_contribution_metadata(contrib.name)
      contrib.description = metadata["dcterms:abstract"]
    end

    return rlt
  end

  # other user's contributions
  def shared_contributions
    rlt = []
    tmp = []

    if current_user.present?
      tmp = Contribution.where("owner_id <> #{current_user.id}").order(:name)
    else
      tmp = Contribution.order(:name)
    end

    tmp.each do |contrib|
      # replace description with abstract for display purpose
      # contrib.description = MetadataHelper::load_metadata_from_contribution(contrib.name)[:abstract]
      metadata = ContributionsHelper.load_contribution_metadata(contrib.name)
      contrib.description = metadata["dcterms:abstract"]

      hash = {}
      hash[:id] = contrib.id
      hash[:name] = contrib.name
      hash[:owner] = "#{contrib.owner.full_name}(#{contrib.owner.email})"
      hash[:collection_name] = contrib.collection.name
      hash[:url] = contrib_show_url(contrib.id)
      hash[:description] = contrib.description
      hash[:accessible] = ContributionsHelper.accessible(current_user, contrib.id)

      rlt << hash
    end

    return rlt
  end

  #
  # Validates that the given request parameters contains the required fields
  #
  def validate_required_web_fields(request_params, required_fields)
    required_fields.each do |key, value|
      raise ResponseError.new(400), "Required field '#{value}' is missing" if request_params[key].blank?
    end
  end


end
