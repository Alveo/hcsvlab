require "#{Rails.root}/lib/rdf-sesame/hcsvlab_server.rb"

module ItemListsHelper

  def self.create_item_list(current_user, params, format = "html")
    logger.debug "create_item_list: start - current_user[#{current_user}], params[#{params}], format[#{format}]"

    rlt = nil
    name = ""
    mdata = {"basic" => {}, "ext" => {}}

    if format == "json"
      name = params[:name]
    else
      # html
      name = params[:item_list][:name]
      mdata["basic"]["dcterms:title"] = name
      mdata["basic"]["dcterms:creator"] = current_user.full_name
      mdata["basic"]["dcterms:abstract"] = params[:item_list][:abstract]
    end

    rlt = current_user.item_lists.find_or_initialize_by_name(name)
    rlt.set_metadata(mdata)

    logger.debug "create_item_list: end - rlt[#{rlt}]"

    return rlt
  end

  # Update item list
  #
  # Input:
  # attr[:id] - item list id
  # attr[:name] - item list name
  # attr[:abstract] - item list abstract
  # attr[:additional_key][] - extensible metadata key
  # attr[:additional_value][] - extensible metadata value
  #
  # Return:
  # {:item_list => item_list, :message => error message}
  #
  # success: :item_list object, :message nil
  # failure: :item_list nil, :message contains reason
  def self.update_item_ist(current_user, attr)
    logger.debug "update_item_list: start - current_user[#{current_user}], attr[#{attr}]"

    rlt = {:item_list => nil, :message => "unknown error"}

    # validate name length
    if attr[:name].blank? || attr[:name].length > 255
      rlt[:message] = "Error trying to update Item list, name length must between 1 to 255"
      logger.debug "update_item_list: end - rlt[#{rlt}]"

      return rlt
    end

    # validate duplicated name
    il = current_user.item_lists.find_by_name(attr[:name])
    if !il.present?
      # congrats! no item list with this name
      # DB update
      il = ItemList.find_by_id(attr[:id])
      il.name = attr[:name]
      il.save!
    else
      #   further check whether duplicated
      if il.id != attr[:id]
        #   found duplicated item list name
        rlt[:message] = "Error trying to update Item list, name '#{attr[:name]}' already exists"
        logger.debug "update_item_list: end - rlt[#{rlt}]"

        return rlt
      end
    end

    # sesame update
    # only after both item_list and items_in_item_list have been updated, can we update sesame accordingly
    update_metadata(il, attr)

    rlt[:item_list] = il
    rlt[:message] = nil

    logger.debug "update_item_list: end - rlt[#{rlt}]"
    return rlt
  end

  def self.destroy_item_list(item_list_id)
    logger.debug "destroy_item_list: start - item_list_id[#{item_list_id}]"

    item_list = ItemList.find_by_id(item_list_id)
    colls = item_list.get_item_handles.collect {|item| item.split(":")[0]}.uniq

    # DB destroy
    item_list.destroy

    # Sesame delete
    uri = Rails.application.routes.url_helpers.item_list_url(item_list_id)
    query = %(
      DELETE {?s ?p ?o.}
      WHERE {
        ?s ?p ?o.
        FILTER(?s = <#{uri}>)
      }
    )

    colls.each do |coll_name|
      logger.debug "destroy_item_list: coll_name[#{coll_name}]"

      repo = MetadataHelper.get_repo_by_collection(coll_name)
      logger.debug "destroy_item_list: sparql query[#{query}]"
      repo.sparql_query(query)
    end

    logger.debug "destroy_item_list: end"
  end

  # Return item list metadata (json)
  #
  # e.g.,
  #
  # {
  #   "basic" : {
  #     "dcterms:title" : "example item list for speaker",
  #     "dcterms:isPartOf" : {
  #       "austalk" : "https://xxx",
  #       "sample" : "https://xxx"
  #      },
  #     "dcterms:abstract" : "anyway, i like durian",
  #     "dcterms:creator" : "Karl LI"
  #   },
  #   "ext" : {
  #     "name1" : "value1",
  #     "name2" : "value2"
  #   }
  # }
  def self.load_metadata(item_list_id)
    logger.debug "load_metadata: start - item_list_id[#{item_list_id}]"

    # collect associated collections from DB
    handles = ItemsInItemList.where(item_list_id: item_list_id).pluck(:handle)
    colls = handles.map {|h| h.split(":")[0]}.uniq

    logger.debug "load_metadata: handles[#{handles}], colls[#{colls}]"

    # use the first associated collection's repo
    repo = MetadataHelper::get_repo_by_collection(colls[0])

    # compose query
    query = %(
      PREFIX alveo: <http://alveo.edu.au/schema/>
      PREFIX dcterms: <http://purl.org/dc/terms/>

      SELECT ?property ?value
      WHERE {
        ?item_list a alveo:ItemList.
        ?item_list dcterms:identifier "#{Rails.application.routes.url_helpers.item_list_url(item_list_id)}".
        ?item_list ?property ?value.
      }
    )
    logger.debug "load_metadata: query[#{query}]"
    query_rlt = repo.sparql_query(query)

    rlt = JSON.parse %(
      {
        "basic":{},
        "ext":{}
      })

    if query_rlt.size != 0
      tmp_hash = {}
      query_rlt.each do |solution|
        key = solution.to_h[:property].to_s
        value = solution.to_h[:value].to_s
        tmp_hash[key] = value
      end

      tmp_hash = JSON::LD::API.compact(tmp_hash, JsonLdHelper::default_context)

      tmp_hash.each do |key, value|
        case key
        when "dcterms:title", "dcterms:isPartOf", "dcterms:identifier", "dcterms:creator", "dcterms:abstract", "rdf:type"
          rlt["basic"][key] = value
        else
          if key != "@context"
            rlt["ext"][key] = value
          end

        end
      end
    end

    # update dcterms:isPartOf according to DB
    rlt["basic"]["dcterms:isPartOf"] = colls.join(",")

    logger.debug "load_metadata: end - rlt[#{JSON.pretty_generate(rlt)}]"

    return rlt

  end

  def self.update_metadata(item_list, attr = nil)
    uri = Rails.application.routes.url_helpers.item_list_url(item_list.id)

    colls = item_list.get_item_handles.collect {|h| h.split(":")[0]}.uniq

    logger.debug "update_metadata: colls[#{colls}]"

    # compose extensible metadata
    md_hash = {}
    ext_prefix = {}
    if !attr[:additional_key].blank?
      #   yes, we have extensible metadata to handle
      md_hash = CollectionsHelper.validate_collection_additional_metadata(attr)
      default_context = JsonLdHelper.default_context
      md_hash.each do |key, value|
        # prepare prefix
        if !key.include?("http://")
          #   compact mode, need prefix
          pfx_name = key.downcase.split(":")[0]
          if !ext_prefix.key?(pfx_name)
            # new to prefix
            if default_context[pfx_name].present?
              #     ok, that's in default context
              ext_prefix[pfx_name] = default_context[pfx_name]["@id"]
            else
              logger.info "update_metadata: unknown context '#{key}'"
            end
          end
        else
          # REALLY? user input complete URI metadata context
          # so no need to provide prefix
          logger.info "update_metadata: complete URI metadata - [#{key} : #{value}]"
        end
      end
    end

    prefix_str = ""
    mdata_str = ""
    ext_prefix.each do |key, value|
      prefix_str += %(PREFIX #{key}: <#{value}>\n)
    end

    md_hash.each do |key, value|
      mdata_str += %(#{key} "#{value}";\n)
    end


    query = %(
      PREFIX alveo: <http://alveo.edu.au/schema/>
      PREFIX dcterms: <http://purl.org/dc/terms/>
      #{prefix_str}

      DELETE WHERE {
        ?item_list ?property ?value.
        ?item_list a alveo:ItemList .
        ?item_list dcterms:identifier "#{uri}" .
      };

      INSERT DATA {
        <#{uri}> a alveo:ItemList;
        #{mdata_str}
        dcterms:identifier "#{uri}";
        dcterms:title "#{item_list.name}";
        dcterms:isPartOf "#{colls.join(',')}";
        dcterms:creator "#{attr.nil? ? item_list.user.full_name : attr[:creator]}";
        dcterms:abstract "#{attr.nil? ? item_list.abstract : attr[:abstract]}".
      }
    )

    colls.each do |coll_name|
      logger.debug "update_metadata: coll_name[#{coll_name}]"

      repo = MetadataHelper.get_repo_by_collection(coll_name)
      logger.debug "update_metadata: sparql query[#{query}]"
      repo.sparql_query(query)
    end
  end


end