require 'spec_helper'

describe Contribution do
  # pending "add some examples to (or delete) #{__FILE__}"

  it "has a valid factory" do
    expect(FactoryGirl.build(:contribution)).to be_valid
  end

  it "has correct associated collection" do
    contrib = FactoryGirl.create(:contribution)
    coll = Collection.find_by_id(contrib.collection_id)
    expect(contrib.name).to start_with("#{coll.name}-contrib")
  end
end

describe Contribution, 'validation' do
  it {should validate_uniqueness_of(:name)}
  it {should validate_presence_of(:name)}

  it {should validate_presence_of(:owner)}

  it {should validate_presence_of(:collection)}
end

describe Contribution, 'association' do
  it {should belong_to(:collection)}
  it {should belong_to(:owner)}
end
