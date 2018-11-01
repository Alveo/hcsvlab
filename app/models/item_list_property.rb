class ItemListProperty < ActiveRecord::Base
  attr_accessible :id, :property, :value

  belongs_to :item_list, inverse_of: :item_list_properties

  validates :property, presence: true
  validates :value, presence: true
end
