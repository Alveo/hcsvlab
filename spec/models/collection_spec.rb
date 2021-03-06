require 'spec_helper'

describe Collection do
  before(:each) do
    # Collection.delete_all
    # CollectionProperty.delete_all
  end
  after(:each) do
    # Collection.delete_all
    # CollectionProperty.delete_all
  end

  it "has a valid factory" do
    expect(FactoryGirl.create(:collection)).to be_valid
  end

  it "has correct association with user" do
    coll = FactoryGirl.create(:collection, :owner => FactoryGirl.create(:user_data_owner))
    user = coll.owner
    expect(user.role.name).to eq(Role::DATA_OWNER_ROLE)
  end

  describe "Collection Descriptive Metadata" do
    it "should persist metadata about a Collection" do
      coll = Collection.new
      coll.uri = 'http://ns.ausnc.org.au/colly'
      coll.name = 'colly'
      coll.save
      id = coll.id

      coll2 = Collection.find(id)
      coll2.uri.should eq 'http://ns.ausnc.org.au/colly'
      coll2.name.should eq 'colly'
    end
  end


  it "is valid with a name, private, text and uri" do
    expect(build(:collection)).to be_valid
  end

  it "is invalid without a name" do
    c = build(:collection, name: nil)
    c.valid?
    expect(c.errors[:name]).to include("can't be blank")
  end

  it "is invalid with a duplicated name" do
    uni_name = "unique GCSAUSE"
    create(:collection, name: uni_name)
    # c = build(:collection, name: uni_name)
    # c.valid?
    # puts c.inspect
    # expect(c.errors[:name]).to include("has already been taken")

    expect {
      c = build(:collection, name: uni_name)
    }.to raise_error(ActiveRecord::RecordInvalid, 'Validation failed: Name has already been taken')
  end

  it "is valid without a text" do
    expect(build(:collection, text: nil)).to be_valid
  end

  it "is valid without a private" do
    expect(build(:collection, private: nil)).to be_valid
  end

  it "is invalid without a uri" do
    c = build(:collection, uri: nil)
    c.valid?
    expect(c.errors[:uri]).to include("can't be blank")
  end


  describe "has at least 6 properties", :focus => true do
    context "exactly 6 properties" do
      it "is valid when has 6 properties" do
        collection = create(:collection)
        expect(collection.collection_properties.count).to eq 6
        # expect(create(:collection_standard_properties).collection_properties.count).to eq 6
        collection.collection_properties.each do |cp|
          expect(cp.property.length).to be > 0
          expect(cp.value.length).to be > 0
        end
      end
    end

    context "less than 6 properties" do
      it "is invalid when less than 6 properties" do

      end
    end

    context "more than 6 properties" do
      it "is valid when more than 6 properties" do

      end
    end
  end

end

describe Collection, 'validation' do
  it {should validate_uniqueness_of(:name)}
  it {should validate_presence_of(:name)}

  it {should validate_presence_of(:uri)}
  it {should validate_presence_of(:status)}
end

describe Collection, 'association' do
  it {should have_many(:items)}
  it {should have_many(:collection_properties)}
  it {should have_many(:attachments)}

  it {should belong_to(:owner)}
  it {should belong_to(:collection_list)}
  it {should belong_to(:licence)}
end