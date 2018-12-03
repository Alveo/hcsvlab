module Item::DownloadItemsHelper
  require Rails.root.join('lib/api/node_api')


  DEFAULT_DOCUMENT_FILTER = '*'
  EXAMPLE_DOCUMENT_FILTER = '*-raw.txt'

  def get_files_by_items(item_handles, document_filter=DEFAULT_DOCUMENT_FILTER)
    logger.debug "get_files_by_items: start item_handles=#{item_handles}, document_filter=#{document_filter}"
    DownloadItemsInFormat.new(current_user, current_ability).get_files(item_handles, document_filter)
    logger.debug "get_files_by_items: end"
  end

  #
  # Download documents as zip
  #
  # file_structure: flat or bagit
  #
  def download_as_zip(itemHandles, file_name, document_filter=DEFAULT_DOCUMENT_FILTER, file_structure='flat')
    begin
      cookies.delete("download_finished")

      bench_start = Time.now

      # Creates a ZIP file containing the documents and item's metadata
      zip_path = DownloadItemsInFormat.new(current_user, current_ability).create_and_retrieve_zip_path(itemHandles, document_filter, file_structure)

      logger.debug("download_as_zip: Time for generating zip as #{file_structure} for #{itemHandles.length} items: (#{'%.1f' % ((Time.now.to_f - bench_start.to_f)*1000)}ms)")

      bench_start = Time.now

      send_file zip_path, :type => 'application/zip',
                :disposition => 'attachment',
                :filename => file_name

      Rails.logger.debug("download_as_zip: Time for downloading zip: (#{'%.1f' % ((Time.now.to_f - bench_start.to_f)*1000)}ms)")

      cookies["download_finished"] = {value: "true", expires: 1.minute.from_now}

      return

    rescue Exception => e

      Rails.logger.error(e.inspect + "\n " + e.backtrace.join("\n "))
    ensure
      # Ensure zipped file is removed
      # FileUtils.rm zip_path if !zip_path.nil?
    end
    respond_to do |format|
      format.html {
        flash[:error] = "Sorry, an unexpected error occur."
        redirect_to @item_list and return
      }
      format.any {render :json => {:error => "Internal Server Error"}.to_json, :status => 500}
    end
  end

  def self.filter_item_files(filenames, filter=DEFAULT_DOCUMENT_FILTER)
    if filter == DEFAULT_DOCUMENT_FILTER
      filenames
    else
      filtered_filenames = []
      filenames.each do |filename|
        if filter == 'no extension' && File.extname(filename) == ""
          filtered_filenames << filename
        else
          filtered_filenames.push filename if File.fnmatch(filter, File.basename(filename), File::FNM_EXTGLOB)
        end
      end
      filtered_filenames
    end
  end

  #
  # Clean tmp download dir
  #
  def self.tmp_dir_cleaning
    logger.debug "tmp_dir_cleaning: start"

    # collect tmp file names
    filenames = Dir[File.join(APP_CONFIG['download_tmp_dir'], "*")].select {|f| File.file?(f)}
    logger.debug filenames
    filenames.each do |filename|
      if filter_expired_tmp_files(filename)
        #   match, can delete
        File.delete(filename)
        logger.debug "tmp_dir_cleaning: #{filename} deleted"
      end
    end

    logger.debug "tmp_dir_cleaning: end"
  end

  # Filter file by:
  #
  # 1. filename - if filename contains timestamp info (xxx_[timestamp].tmp)
  # 2. else, check file creation time (File.mtime)
  #
  # @param [String] filename
  # @param [String] expired_time (hours)
  # @return true if filename match (expired), otherwise false
  #
  def self.filter_expired_tmp_files(filename, expired_time=APP_CONFIG['download_expired_time'])
    logger.debug "filter_expired_tmp_files: start filename=#{filename}, expired_time=#{expired_time}"
    rlt = false

    unless filename.nil?
      # check filename
      timestamp = nil
      if match = filename.match(/.+_(\d+)\.tmp$/)
        timestamp = match.captures.first
      end

      i_timestamp = -1

      begin
        if timestamp.nil?
          #   can't extract timestamp info from filename, so extract from file creation time
          i_timestamp = File.mtime(filename).to_i
        else
          i_timestamp = timestamp.to_i
        end

        if (Time.now.getutc.to_i - i_timestamp) > expired_time.to_i*60*60
          rlt = true
        end

      rescue Exception => e
        logger.error e.message
      end
    end

    logger.debug "filter_expired_tmp_files: end rlt=#{rlt}"
    return rlt

  end

  class DownloadItemsInFormat
    include Blacklight::Configurable
    include Blacklight::SolrHelper
    include ActiveSupport::Rescuable
    include Hydra::Controller::ControllerBehavior

    FIXNUM_MAX = 2147483647
    #
    # Class variables for information about Solr
    #
    @@solr_config = nil
    @@solr = nil

    # Indicate Hydra to add access control to the SOLR requests
    self.solr_search_params_logic += [:add_access_controls_to_solr_params]
    self.solr_search_params_logic += [:exclude_unwanted_models]

    #
    #
    #
    def initialize (current_user = nil, current_ability = nil)
      @current_user = current_user
      @current_ability = current_ability
    end

    def get_files(item_handles, document_filter)
      result = verify_items_permissions_and_extract_metadata(item_handles, document_filter)

      filenames_by_item = get_filenames_from_item_results(result)

      filenames = []
      filenames_by_item.each_value do |value|
        Item::DownloadItemsHelper.filter_item_files(value[:files], document_filter).each do |file|
          # The original file, including the path to find it
          filenames << file.to_s

          # TODO: if remote, fetch to tmp
        end
      end

      filenames
    end

    def create_and_retrieve_zip_path(item_handles, document_filter, file_structure)
      logger.debug "create_and_retrieve_zip_path: start item_handles[#{item_handles}], document_filter[#{document_filter}], file_structure[#{file_structure}]"
      rlt = zip_as_flat(item_handles, document_filter)

      logger.debug "create_and_retrieve_zip_path: end #{rlt}"

      rlt
    end

    #
    # Retrieve filenames from documents.file_path thru items. Would remove duplicated filenames.
    #
    # @param [String] item_handles
    # @param [String] document_filter
    # @return [Array of String]
    def get_filenames_from_item(item_handles, document_filter)
      logger.debug "get_filenames_from_item: start - item_handles[#{item_handles}], document_filter[#{document_filter}]"

      rlt = []
      filenames = []

      item_handles.each do |handle|
        item = Item.find_by_handle(handle)

        if !item.nil?
          docs = Document.find_all_by_item_id(item.id)

          docs.each do |doc|
            filenames << doc.file_path
          end
        end
      end

      # finally remove duplicated filenames
      filenames = filenames.uniq

      Item::DownloadItemsHelper.filter_item_files(filenames, document_filter).each do |file|
        rlt << file
      end

      logger.debug "get_filenames_from_item: end - rlt[#{rlt}]"

      rlt
    end

    # @param [Array of String] item_handles
    # @param [String] document_filter
    # @return [String]
    def zip_as_flat(item_handles, document_filter)
      rlt = nil

      if item_handles.present?
        begin
          result = verify_items_permissions_and_extract_metadata(item_handles, document_filter)
          digest_filename = Digest::MD5.hexdigest(result[:valids].inspect.to_s) + "_" + Time.now.getutc.to_i.to_s

          # retrieve filenames from documents.file_path by item
          filenames = get_filenames_from_item(item_handles, document_filter)

          # Set download_tmp_dir as an absolute path if it starts with "/"
          # or otherwise relative to Rails.root
          tmp_dir = APP_CONFIG['download_tmp_dir']
          if !tmp_dir.start_with?("/")
            tmp_dir = Rails.root.join(APP_CONFIG['download_tmp_dir'])
          end

          FileUtils.mkdir_p(tmp_dir) unless File.directory?(tmp_dir)
          zip_path = File.join(tmp_dir, "#{digest_filename}.tmp")

          ZipBuilder.build_simple_zip_from_files(zip_path, filenames)

          rlt = zip_path
        rescue Exception => e
          logger.error "zip_as_flat: #{e.message}"
        end
      end

      rlt
    end

    private

    def get_items_files(result, document_filter)
      filenames = get_filenames_from_item_results(result)
      filenames.map do |key, value|
        dir = value[:handle]
        files = Item::DownloadItemsHelper.filter_item_files(value[:files], document_filter)
        files.map {|file| {dir: dir, file: file}}
      end.flatten
    end

    #
    #
    #
    def verify_items_permissions_and_extract_metadata(item_handles, document_filter, batch_group=2500)
      valids = []
      invalids = []
      metadata = {}

      licence_ids = UserLicenceAgreement.where(user_id: @current_user.id).pluck('distinct licence_id')
      t = Collection.arel_table
      collection_ids = Collection.where(t[:licence_id].in(licence_ids).or(t[:owner_id].eq(current_user.id))).pluck(:id)

      bench_start = Time.now
      audit_info = []

      item_handles.in_groups_of(batch_group, false) do |item_handle_group|
        query = Item.indexed.where(collection_id: collection_ids, handle: item_handle_group).select([:id, :handle, :json_metadata])
        valids = query.collect(&:handle)
        query.each do |item|
          begin
            json = JSON.parse(item.json_metadata)
          rescue
            Rails.logger.debug("Error parsing json_metadata for document #{item.id}")
          end
          metadata[item.id] = {}
          if json.has_key? 'documentsLocations'
            metadata[item.id][:files] = json['documentsLocations'].clone.values.flatten
            json.delete('documentsLocations')
          else
            files = []
            json['ausnc:document'].each {|doc|
              files << doc['dcterms:source']
            }
            metadata[item.id][:files] = files
            json['metadata'] = {'handle' => item.handle}
          end
          metadata[item.id][:metadata] = json
          item.documents.each do |doc|
            # DocumentAudit.create(document: doc, user: current_user)

            # only handle filtered document
            filtered_file = Item::DownloadItemsHelper.filter_item_files(Array.[](doc.file_name), document_filter)
            if filtered_file.size > 0
              arr = []
              arr[0] = doc.id
              arr[1] = current_user.id
              audit_info << arr
            end
          end
        end

        invalids += item_handle_group - valids

      end

      DocumentAudit.batch_create(audit_info)

      bench_end = Time.now

      logger.debug "verify_items_permissions_and_extract_metadata: total document_audit: #{audit_info.size}, elasped: #{'%.1f' % ((bench_end.to_f - bench_start.to_f)*1000)}ms"

      {valids: valids, invalids: invalids, metadata: metadata}
    end


    # filenames_by_item = Hash structure containing the items id as key and the list of files as value
    # Example:
    #   {"hcsvlab:1003"=>{handle: "handle1", files:["full_path1, full_path2, .."]} ,
    #   "hcsvlab:1034"=>{handle: "handle2", files:["full_path4, full_path5, .."]}}
    def get_filenames_from_item_results(result)
      metadata = result[:metadata]

      fileNamesByItem = {}
      metadata.each_pair do |key, value|
        handle = value[:metadata]['metadata']['handle'].gsub(':', '_')
        files = value[:files].map {|filename| filename.to_s.gsub(/(^file:(\/)+)/, "/")}
        fileNamesByItem[key] = {handle: handle, files: files}
      end

      fileNamesByItem
    end

    #
    # blacklight uses this method to get the SOLR connection.
    def blacklight_solr
      get_solr_connection
      @@solr
    end

    #
    # Initialise the connection to Solr
    #
    def get_solr_connection
      if @@solr_config.nil?
        @@solr_config = Blacklight.solr_config
        @@solr = RSolr.connect(@@solr_config)
      end
    end

    #
    #
    #
    def current_user
      @current_user
    end

    #
    #
    #
    def current_ability
      @current_ability
    end
  end
end
