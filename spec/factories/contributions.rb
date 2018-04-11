# Read about factories at https://github.com/thoughtbot/factory_girl

FactoryGirl.define do
  factory :contribution do
    sequence(:name) {|n| "#{collection.name}-contrib_#{n}"}
    association :collection
    owner { collection.owner }
    description {"Long long ago there was a description in [#{name}]...the end."}
  end
end
