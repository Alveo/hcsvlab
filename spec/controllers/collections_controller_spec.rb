require 'spec_helper'

RSpec.describe CollectionsController, :type => :controller do

  before :each do
    request.env["HTTP_ACCEPT"] = 'text/html'
  end

  let(:data_owner) {FactoryGirl.create(:user_data_owner)}
  let(:my_collection) {FactoryGirl.create(:collection, owner: data_owner)}

  # shared_examples 'public access to controllers' do
  describe 'GET collection home page' do

    context 'with params[:name]', :focus => true do
      it "populates a specific collection" do
        sign_in data_owner
        get :show, id: my_collection.name
        expect(assigns(:collection)).to eq my_collection
        expect(assigns(:attachment_url)).to eq collection_attachments_path(my_collection.id)
      end

      it "renders the :index template" do
        # = render :file => '/collections/show'
        sign_in data_owner
        get :show, id: my_collection.name
        expect(response).to render_template :show
      end

    end

    context 'without params' do
      it "populates an array of all collections" do
        get :index
        expect(assigns(:collections)).to match_array(controller.collections_by_name)
        # expect(assigns(:collection_lists)).to match_array(controller.lists_by_name)
      end

      it "renders the :index template" do
        get :index
        expect(response).to render_template :index
      end
    end
  end

  describe "GET #show" do
    it "assigns the requested Collection object to @collection" do
      pending "..."
    end

    it "renders the :show template" do
      pending "..."
    end
  end
  # end


  describe 'admin access' do
    pending "..."
  end

  describe 'researcher access' do
    pending "..."
  end

  describe 'data owner access' do
    pending "..."
  end


  # describe "GET #new" do
  #   it "assigns a new Collection object to @collection "
  #   it "renders the :new template"
  # end
  #
  # describe "GET #edit" do
  #   it "assigns the requested Collection object to @collection"
  #   it "renders the :edit template"
  # end
  #
  # describe "POST #create" do
  #   context "with valid attributes" do
  #     it "save the new collection in DB"
  #     it "redirects to collection#show"
  #   end
  #
  #   context "with invalid attributes" do
  #     it "does not save the new collection in DB"
  #     it "re-renders the :new template"
  #   end
  # end
  #
  # describe "PATCH #update" do
  #   context "with valid attributes" do
  #     it "updates the collection in DB"
  #     it "redirects to the collection#show"
  #   end
  #
  #   context "with invalid attributes" do
  #     it "does not update the collection"
  #     it "re-renders the :edit template"
  #   end
  # end
  #
  # describe "DELETE #destroy" do
  #   context "with valid collection id" do
  #     it "deletes the collection from DB"
  #     it "redirects to collection home page"
  #   end
  #
  #   context "with invalid collection id" do
  #     it "does not delete collection from DB"
  #     it "re-renders the :show template"
  #   end
  # end

end
