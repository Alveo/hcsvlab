require "#{Rails.root}/lib/tasks/fedora_helper.rb"

class SpeakersController < ApplicationController

  before_filter :authenticate_user!
  before_filter :ensure_json_request

  # GET returns a list of speaker identifiers (URIs) associated with this collection
  def index
    logger.debug "speakers#index start"

    collection_name = params[:collection]
    collection = Collection.find_by_name(collection_name)

    if collection.nil?
      # collection not found
      render json: {errors: {
        id: "no_record",
        message: "collection [#{collection_name}] not found"
      }}, status: 422
    else
      #   retrieve speakers
      begin
        ids = SpeakersHelper.find_speaker_by_collection(collection_name)
        @speaker_uri = []
        ids.each do |id|
          @speaker_uri << "#{SESAME_CONFIG["speaker_url"]}/#{collection_name}/#{id}"
        end
      rescue Exception => e
        render json: {errors: {
          id: "repo_error",
          message: e.message
        }}, status: 422
      end
    end

    logger.debug " speakers #index end"
  end

  # POST adds a new speaker from a JSON-LD payload
  def create
    logger.debug "speakers#create start"

    collection_name = params[:collection]
    collection = Collection.find_by_name(collection_name)

    if collection.nil?
      # collection not found
      render json: {errors: {
        id: "no_collection",
        message: "collection [#{collection_name}] not found"
      }}, status: 422
    else
      # check json
      begin
        json = JSON.parse(request.body.read.html_safe)
        speaker_id = ""
        if json.present?
          speaker_id = SpeakersHelper.create_speaker(collection_name, json)
          speaker_uri = request.original_url + "/" + speaker_id
          render json: {success: {
            id: speaker_id,
            message: "speaker created",
            URI: "#{speaker_uri}"
          }}, status: 201, location: speaker_uri
        else
          render json: {errors: {
            id: "error",
            message: "invalid json"
          }}, status: 422
        end
      rescue Exception => e
        logger.error "speakers#create exception[#{e.message}]"

        render json: {errors: {
          id: "error",
          message: e.message
        }}, status: 422
      end
    end

    logger.debug "speakers#create end"
  end

  # GET returns a JSON-LD description of the speaker
  def show
    logger.debug "speakers#show start"

    collection_name = params[:collection]
    collection = Collection.find_by_name(collection_name)

    if collection.nil?
      # collection not found
      render json: {errors: {
        id: "no_collection",
        message: "collection [#{collection_name}] not found"
      }}, status: 422
    else
      # get speaker
      begin
        speaker_id = params[:speaker_id]
        speaker = SpeakersHelper.find_speaker(collection_name, speaker_id)

        if speaker.nil?
          #   speaker not found
          render json: {errors: {
            id: "no_speaker",
            message: "speaker [#{speaker_id}] not found"
          }}, status: 422
        else
          render json: speaker, status: 200
        end
      rescue Exception => e
        render json: {errors: {
          id: "error",
          message: e.message
        }}, status: 422
      end
    end

    logger.debug "speakers#show end"
  end

  # PUT /speakers/{collection_name}/{speaker_id}
  # updates the speaker metadata from a JSON-LD payload
  def update
    logger.debug "speakers#update start"

    collection_name = params[:collection]
    collection = Collection.find_by_name(collection_name)

    if collection.nil?
      # collection not found
      render json: {errors: {
        id: "no_collection",
        message: "collection [#{collection_name}] not found"
      }}, status: 422
    else
      # check json
      begin
        json = JSON.parse(request.body.read.html_safe)
        speaker_id = params[:speaker_id]
        if json.present?
          SpeakersHelper.update_speaker(collection_name, speaker_id, json)

          speaker_uri = request.original_url

          render json: {success: {
            id: speaker_id,
            message: "speaker updated",
            URI: "#{speaker_uri}"
          }}, status: 200, location: speaker_uri
        else
          render json: {errors: {
            id: "error",
            message: "request json parse error"
          }}, status: 422
        end
      rescue Exception => e
        render json: {errors: {
          id: "error",
          message: e.message
        }}, status: 422
      end
    end

    logger.debug "speakers#update end"
  end

  # DELETE /speakers/{collection_name}/{speaker_id}
  # delets the specific speaker's metadata
  def delete
    logger.debug "speakers#delete start"
    collection_name = params[:collection]
    collection = Collection.find_by_name(collection_name)

    if collection.nil?
      # collection not found
      render json: {errors: {
        id: "no_collection",
        message: "collection [#{collection_name}] not found"
      }}, status: 422
    else
      # get speaker
      begin
        speaker_id = params[:speaker_id]
        SpeakersHelper.delete_speaker(collection_name, speaker_id)

        # always return success unless exception
        render json: {success: {
          id: speaker_id,
          message: "speaker [#{speaker_id}] deleted"
        }}, status: 200
      rescue Exception => e
        render json: {errors: {
          id: "error",
          message: e.message
        }}, status: 422
      end
    end
    logger.debug "speakers#delete end"
  end

end
