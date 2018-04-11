require Rails.root.join('lib/api/response_error')
require Rails.root.join('lib/api/request_validator')

class ContributionsController < ApplicationController

  before_filter :authenticate_user!, :except => [:index]

  # GET "contrib/"
  def index
    @contributions = contributions_by_name

    begin
      @contributions.each do |contrib|
        # replace description with abstract for display purpose
        # contrib.description = MetadataHelper::load_metadata_from_contribution(contrib.name)[:abstract]
        metadata = ContributionsHelper.load_contribution_metadata(contrib.name)
        contrib.description = metadata["dcterms:abstract"]
      end

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

      msg, contrib_id = upsert_contribution_core(attr)

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
        :creator => @contribution.owner.full_name,
        :created => @contribution.created_at,
        :abstract => metadata["dcterms:abstract"].to_json
      }

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
      contrib_zip_file = ContributionsHelper.contribution_import_zip_file(contrib)
      FileUtils.mkdir_p(ContributionsHelper.contribution_dir(contrib))
      FileUtils.cp(zip_file.tempfile, contrib_zip_file)
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

      msg, contrib_id = upsert_contribution_core(attr)

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
    contrib = Contribution.find_by_id(id)

    if contrib.nil?
      msg = "Contribution does not exist with the given id: #{params[:id]}"
      logger.warn "export: #{msg}"
      resource_not_found(Exception.new(msg), contrib_index_url)
      return
    end

    begin
      zip_path = ContributionsHelper.export_as_zip(contrib)

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
      end
    end

  end

  # List all contributions by name
  def contributions_by_name
    Contribution.order(:name)
  end

  #
  # Validates that the given request parameters contains the required fields
  #
  def validate_required_web_fields(request_params, required_fields)
    required_fields.each do |key, value|
      raise ResponseError.new(400), "Required field '#{value}' is missing" if request_params[key].blank?
    end
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
  def upsert_contribution_core(attr)
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
      uri = contrib_show_url(contrib.id)

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
      uri = contrib_show_url(contrib.id)

      # compose query
      #
      # e.g.,
      #
      # PREFIX alveo: <http://alveo.edu.au/schema/>
      # PREFIX dcterms: <http://purl.org/dc/terms/>
      #
      # DELETE { ?contrib ?property ?value.}
      # INSERT {
      #   <http://localhost:3000/contrib/9> a alveo:Contribution;
      #   dcterms:identifier "9";
      #   dcterms:title "19Oct.1";
      #   dcterms:creator "Data Owner";
      #   dcterms:created "2017-10-18 23:35:08 UTC";
      #   dcterms:abstract "anyway new".
      # }
      # WHERE {
      #   ?contrib ?property ?value.
      #   FILTER(?contrib = <http://localhost:3000/contrib/9>)
      # }

      query = %(
      PREFIX alveo: <http://alveo.edu.au/schema/>
      PREFIX dcterms: <http://purl.org/dc/terms/>

      DELETE { ?contrib ?property ?value. }
      INSERT {
        <#{uri}> a alveo:Contribution;
        dcterms:identifier "#{MetadataHelper.sqarql_well_formed(contrib.id)}";
        dcterms:title "#{MetadataHelper.sqarql_well_formed(contrib.name)}";
        dcterms:creator "#{MetadataHelper.sqarql_well_formed(contrib.owner.full_name)}";
        dcterms:created "#{MetadataHelper.sqarql_well_formed(contrib.created_at)}";
        dcterms:abstract "#{MetadataHelper.sqarql_well_formed(contrib_abstract)}".
      }
      WHERE {
        ?contrib ?property ?value.
        FILTER(?contrib = <#{uri}>)
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

end
