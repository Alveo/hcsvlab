# Read about factories at https://github.com/thoughtbot/factory_girl

FactoryGirl.define do
  factory :item_list_property, :class => 'ItemListProperties' do
    property "MyString"
    value "MyString"
  end
end
