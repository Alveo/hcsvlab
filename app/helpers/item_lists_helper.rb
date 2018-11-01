require "#{Rails.root}/lib/rdf-sesame/hcsvlab_server.rb"

module ItemListsHelper

  def self.create_item_list(current_user, attr)
    logger.debug "create_item_list: start - attr[#{attr}]"

    rlt = nil

    rlt = current_user.item_lists.find_or_initialize_by_name(attr[:name])

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
  def self.update_item_ist(attr)
    logger.debug "update_item_list: start - attr[#{attr}]"

    rlt = {:item_list => nil, :message => "unknown error"}

    # validate name length
    if attr[:name].blank? || attr[:name].length > 255
      rlt[:message] = "Error trying to update Item list, name length must between 1 to 255"
      logger.debug "update_item_list: end - rlt[#{rlt}]"

      return rlt
    end

    # validate duplicated name
    il = ItemList.find_by_name(attr[:name])
    if !il.present?
      # congrats! no item list with this name
      # DB update
      il = ItemList.find_by_id(attr[:id])
      il.name = attr[:name]
    else
      #   further check whether duplicated
      if il.id != attr[:id]
        #   found duplicated item list name
        rlt[:message] = "Error trying to update Item list, name '#{attr[:name]}' already exists"
        logger.debug "update_item_list: end - rlt[#{rlt}]"

        return rlt
      end
    end

    # only after both item_list and items_in_item_list have been updated, can we update metadata accordingly
    il.save!
    il.set_metadata(convert_metadata(attr))
    il.update_metadata

    rlt[:item_list] = il
    rlt[:message] = nil

    logger.debug "update_item_list: end - rlt[#{rlt}]"
    return rlt
  end

  def self.destroy_item_list(item_list_id)
    logger.debug "destroy_item_list: start - item_list_id[#{item_list_id}]"

    item_list = ItemList.find_by_id(item_list_id)
    # colls = item_list.get_item_handles.collect {|item| item.split(":")[0]}.uniq

    # DB destroy
    item_list.destroy

    # # Sesame delete
    # uri = Rails.application.routes.url_helpers.item_list_url(item_list_id)
    # query = %(
    #   DELETE {?s ?p ?o.}
    #   WHERE {
    #     ?s ?p ?o.
    #     FILTER(?s = <#{uri}>)
    #   }
    # )
    #
    # colls.each do |coll_name|
    #   logger.debug "destroy_item_list: coll_name[#{coll_name}]"
    #
    #   repo = MetadataHelper.get_repo_by_collection(coll_name)
    #   logger.debug "destroy_item_list: sparql query[#{query}]"
    #   repo.sparql_query(query)
    # end

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

    # # use the first associated collection's repo
    # repo = MetadataHelper::get_repo_by_collection(colls[0])
    #
    # # compose query
    # query = %(
    #   PREFIX alveo: <http://alveo.edu.au/schema/>
    #   PREFIX dcterms: <http://purl.org/dc/terms/>
    #
    #   SELECT ?property ?value
    #   WHERE {
    #     ?item_list a alveo:ItemList.
    #     ?item_list dcterms:identifier "#{Rails.application.routes.url_helpers.item_list_url(item_list_id)}".
    #     ?item_list ?property ?value.
    #   }
    # )
    # logger.debug "load_metadata: query[#{query}]"
    # query_rlt = repo.sparql_query(query)


    item_list_props = ItemListProperty.find_all_by_item_list_id(item_list_id)

    rlt = JSON.parse %(
      {
        "basic":{},
        "ext":{}
      })

    if item_list_props.size != 0
      tmp_hash = {}
      item_list_props.each do |prop|
        key = prop.property
        value = prop.value
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

  # convert metadata from original attr.
  #
  # attr - attr key-value pari
  def self.convert_metadata(attr)
    logger.debug "convert_metadata: start - attr[#{attr}]"

    rlt = {"basic" => {}, "ext" => {}}

    # basic metadata
    rlt["basic"]["dcterms:title"] = attr[:name]

    if !attr[:id].blank?
      rlt["basic"]["dcterms:identifier"] = Rails.application.routes.url_helpers.item_list_url(attr[:id])
      rlt["basic"]["dcterms:isPartOf"] = ItemList.find_by_id(attr[:id]).get_item_handles.collect {|h| h.split(":")[0]}.uniq.join(',')
    end

    rlt["basic"]["dcterms:creator"] = attr[:creator]
    rlt["basic"]["dcterms:abstract"] = attr[:abstract]

    # ext metadata
    if !attr[:additional_key].blank? && !attr[:additional_value].blank?
      attr[:additional_key].zip(attr[:additional_value]).each do |key, value|
        if key.blank? || value.blank?
          next
        end

        rlt["ext"][key] = value
      end
    end

    logger.debug "convert_metadata: end - rlt[#{rlt}]"

    return rlt

  end

end