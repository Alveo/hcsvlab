require 'spec_helper'

describe SpeakersController, :type => :controller do
  render_views
  login_admin

  before :each do
    request.env["HTTP_ACCEPT"] = 'application/json'
  end

  let(:collection) {FactoryGirl.create(:collection)}
  let(:collection_no_speaker) {FactoryGirl.create(:collection_no_speaker)}

  # GET /speakers/:collection/
  describe 'GET list of speaker identifiers (URIs) associated with specific collection' do
    context 'with specific collection not exists' do
      it 'returns no such collection' do
        # get :index, collection: 'not_found'
        #
        # # test for the 422 status-code
        # expect(response.response_code).to eq(422)
        pending '...'
      end
    end

    context 'with specific collection exists but no speaker within' do
      it 'returns empty list' do
        # get :index, collection: @collection_no_speaker.name
        #
        # # test for the 200 status-code
        # expect(response.response_code).to eq(200)
        #
        # json = JSON.parse(response.body)
        #
        # expect(json).to include_json(speakers: [])
        pending '...'
      end
    end

    context 'with specific collection exists and speaker exists' do
      it 'returns speaker list' do
        # get :index, collection: @collection.name

        # test for the 200 status-code
        # expect(response.response_code).to eq(200)
        # expect return:
        # {
        #   "speakers": [
        #     "URI1",
        #     "URI2"
        #   ]
        # }

        # json = JSON.parse(response.body)
        #
        # expect(json).to include_json(
        #   speakers: [
        #     "https://app.alveo.edu.au/speakers/#{@collection.name}/1_116",
        #     "https://app.alveo.edu.au/speakers/#{@collection.name}/1_117"
        #   ]
        # )
        pending '...'
      end
    end
  end


  # GET /speakers/:collection/:speaker_id
  describe 'GET speaker metadata' do
    context 'with params[:collection] but collection not exists' do
      it 'return no such collection' do
        # get :show, collection: 'not_found', speaker_id: 'whatever'
        #
        # # test for the 422 status-code
        # expect(response.response_code).to eq(422)
        pending '...'
      end
    end

    context 'with collection exists but speaker not exists' do
      it 'returns no such speaker' do
        # get :show, collection: @collection.name, speaker_id: "not_found"
        #
        # # test for the 422 status-code
        # expect(response.response_code).to eq(422)
        pending '...'
      end
    end

    context 'with params[:collection] and collection exists' do
      context 'with params[:speaker_id] and speaker exists' do
        it 'populate a specific speaker metadata' do
          pending '...'
        end
      end

      context 'with params[:speaker_id] but no such speaker' do
        it 'return no such speaker' do
          pending '...'
        end
      end

      context 'without params[:speaker_id]' do
        it 'return no such speaker' do
          pending '...'
        end
      end

    end

  end

end
