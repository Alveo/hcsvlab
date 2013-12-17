require "#{Rails.root}/lib/item/download_items_helper.rb"

class ItemListsController < ApplicationController
  include Blacklight::BlacklightHelperBehavior
  include Blacklight::CatalogHelperBehavior
  include Blacklight::Configurable
  include Blacklight::SolrHelper
  include Item::DownloadItemsHelper

  before_filter :authenticate_user!
  load_and_authorize_resource

  # Set itemList tab as current selected
  set_tab :itemList

  def index
    if (session[:profiler])
      @profiler = session[:profiler]
      session.delete(:profiler)
    end
  end

  def show
    if (session[:profiler])
      @profiler = session[:profiler]
      session.delete(:profiler)
    end

    respond_to do |format|
      format.html {
        @response = @item_list.get_items(params[:page], params[:per_page])
        @document_list = @response["response"]["docs"]

        if current_user.authentication_token.nil? #generate auth token if one doesn't already exist
          current_user.reset_authentication_token!
        end

        render :index
      }
      format.json {
        @response = @item_list.get_items(params[:page], params[:per_page])
        @document_list = @response["response"]["docs"]
      }
      format.zip {
        # Get the items of the item list
        itemsId = @item_list.get_item_ids

        download_as_zip(itemsId, "#{@item_list.name}.zip")
      }
      format.warc {
        # Get the items of the item list
        itemsId = @item_list.get_item_ids

        download_as_warc(itemsId, "#{@item_list.name}.warc")
      }
    end
  end
  
  def create
    if request.format == 'json' and request.post?
      name = params[:name]
      if (!name.nil? and !name.blank?) and (!params[:items].nil? and params[:items].is_a? Array)
        item_lists = current_user.item_lists.where(:name => name)
        if item_lists.empty?
          @item_list = ItemList.new(:name => name, :user_id => current_user.id)
          @item_list.save!
          new_item_list = true
        else
          @item_list = item_lists[0]
          new_item_list = false
        end
        ids = params[:items].collect { |x| File.basename(x) }
        addItemsResult = add_item_to_item_list(@item_list, ids)
        added_set = addItemsResult[:addedItems]
        if new_item_list
          @success_message = "#{added_set.count} items added to new item list #{@item_list.name}"
        else
          @success_message = "#{added_set.count} items added to existing item list #{@item_list.name}"
        end
      else
        err_message = "name parameter" if name.nil? or name.blank?
        err_message = "items parameter" if params[:items].nil?
        err_message = "name and items parameters" if (name.nil? or name.blank?) and params[:items].nil?
        err_message << " not found" if !err_message.nil?
        err_message = "items parameter not an array" if !params[:items].is_a? Array and err_message.nil?
        respond_to do |format|
          format.any { render :json => {:error => err_message}.to_json, :status => 400 }
        end
      end
    else
      if params[:all_items] == 'true'
        documents = @item_list.getAllItemsFromSearch(params[:query_all_params])
      else
        documents = params[:sel_document_ids].split(",")
      end
      if @item_list.save
        flash[:notice] = 'Item list created successfully'
        addItemsResult = add_item_to_item_list(@item_list, documents)
        session[:profiler] = addItemsResult[:profiler]
        redirect_to @item_list
      end
    end
  end

  def add_items
    if params[:add_all_items] == "true"
      documents = @item_list.getAllItemsFromSearch(params[:query_params])
    else
      documents = params[:document_ids].split(",")
    end

    addItemsResult = add_item_to_item_list(@item_list, documents)
    added_set = addItemsResult[:addedItems]

    session[:profiler] = addItemsResult[:profiler]

    flash[:notice] = "#{view_context.pluralize(added_set.size, "")} added to item list #{@item_list.name}"
    redirect_to @item_list
  end

  def clear
    bench_start = Time.now
    removed_set = @item_list.clear
    bench_end = Time.now

    Rails.logger.debug("Time for clear item list of #{removed_set.size} items: (#{'%.1f' % ((bench_end.to_f - bench_start.to_f)*1000)}ms)")
    session[:profiler] = ["Time for clear item list of #{removed_set.size} items: (#{'%.1f' % ((bench_end.to_f - bench_start.to_f)*1000)}ms)"]

    flash[:notice] = "#{view_context.pluralize(removed_set.size, "")} cleared from item list #{@item_list.name}"
    redirect_to @item_list
  end

  def destroy
    bench_start = Time.now

    name = @item_list.name
    removed_set = @item_list.clear
    @item_list.delete

    bench_end = Time.now

    Rails.logger.debug("Time for deleting an Item list of #{removed_set.size} items: (#{'%.1f' % ((bench_end.to_f - bench_start.to_f)*1000)}ms)")
    session[:profiler] = ["Time for deleting an Item list of #{removed_set.size} items: (#{'%.1f' % ((bench_end.to_f - bench_start.to_f)*1000)}ms)"]

    flash[:notice] = "Item list #{name} deleted successfully"
    redirect_to item_lists_path
  end

  def concordance_search
    result = @item_list.doConcordanceSearch(params[:concordance_search_for])

    if (result[:error].nil? or result[:error].empty?)
      @highlighting = result[:highlighting]
      @matchingDocs = result[:matching_docs]
      @profiler = result[:profiler]
      flash[:error] = nil
    else
      flash[:error] = result[:error]
    end

  end

  def frequency_search
    result = @item_list.doFrequencySearch(params[:frequency_search_for], params[:facet])
    if (result[:error].nil? or result[:error].empty?)
      flash[:error] = nil
      @result = result
    else
      flash[:error] = result[:error]
    end
  end

  private

  #
  #
  #
  def download_as_zip(itemsId, file_name)
    begin
      cookies.delete("download_finished")

      bench_start = Time.now

      # Creates a ZIP file containing the documents and item's metadata
      zip_path = DownloadItemsAsArchive.new(current_user, current_ability).createAndRetrieveZipPath(itemsId) do |aDoc|
        @itemInfo = create_display_info_hash(aDoc)
        renderer = Rabl::Renderer.new('catalog/show', @itemInfo, { :format => 'json', :view_path => 'app/views', :scope => self })
        itemMetadata = renderer.render
        itemMetadata
      end

      # Sends the zipped file
      send_data IO.read(zip_path), :type => 'application/zip',
                :disposition => 'attachment',
                :filename => file_name

      Rails.logger.debug("Time for downloading metadata and documents for #{itemsId.length} items: (#{'%.1f' % ((Time.now.to_f - bench_start.to_f)*1000)}ms)")
      cookies["download_finished"] = {value:"true", expires: 1.minute.from_now}
      return

    rescue Exception => e
      Rails.logger.error(e.message + "\n " + e.backtrace.join("\n "))
    ensure
      # Ensure zipped file is removed
      FileUtils.rm zip_path if !zip_path.nil?
    end
    respond_to do |format|
      format.html {
        flash[:error] = "Sorry, an unexpected error occur."
        redirect_to @item_list and return
      }
      format.any { render :json => {:error => "Internal Server Error"}.to_json, :status => 500 }
    end
  end

  #
  #
  #
  def download_as_warc(itemsId, file_name)
    begin
      cookies.delete("download_finished")

      bench_start = Time.now

      dont_show = Set.new(Item.development_only_fields)

      # Creates a WARC file containing the documents and item's metadata
      archive_path = DownloadItemsAsArchive.new(current_user, current_ability).createAndRetrieveWarcPath(itemsId, request.original_url) do |aDoc|
        @document = aDoc
        itemMetadata = {}
        keys = aDoc.keys
        aDoc.keys.each { |key|
          itemMetadata[key] = aDoc[key].join(', ') unless dont_show.include?(key)
        }
        itemMetadata
      end

      # Sends the archive file
      send_data IO.read(archive_path), :type => 'application/warc',
                :disposition => 'attachment',
                :filename => file_name

      Rails.logger.debug("Time for downloading metadata and documents for #{itemsId.length} items: (#{'%.1f' % ((Time.now.to_f - bench_start.to_f)*1000)}ms)")
      cookies["download_finished"] = {value:"true", expires: 1.minute.from_now}
      return

    rescue Exception => e
      Rails.logger.error(e.message + "\n " + e.backtrace.join("\n "))
    ensure
      # Ensure archive file is removed
      FileUtils.rm archive_path if !archive_path.nil?
    end
    respond_to do |format|
      format.html {
        flash[:error] = "Sorry, an unexpected error occur."
        redirect_to @item_list and return
      }
      format.any { render :json => {:error => "Internal Server Error"}.to_json, :status => 500 }
    end
  end

  def add_item_to_item_list(item_list, documents_ids)
    item_list.add_items(documents_ids) unless item_list.nil?
  end

end