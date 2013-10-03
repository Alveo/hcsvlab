include ActiveFedora::DatastreamCollections
require "#{Rails.root}/lib/solr/solr_helper.rb"

class Collection < ActiveFedora::Base
  include SolrHelper

  # Adds useful methods form managing Item groups
  include Hydra::ModelMixins::RightsMetadata

  has_metadata 'descMetadata', type: Datastream::CollectionMetadata
  has_metadata 'rdfMetadata', type: ActiveFedora::RdfxmlRDFDatastream
  has_metadata :name => "rightsMetadata", :type => Hydra::Datastream::RightsMetadata

  has_many :items, :property => :is_member_of_collection
  belongs_to :collectionList, :property => :is_part_of
  belongs_to :licence, :property => :has_licence

  # uri is the unique id of the collection, e.g. http://ns.ausnc.org.au/corpora/cooee
  delegate :uri, to: 'descMetadata'

  # short_name is a nice human readable handy-type name, e.g. COOEE
  delegate :short_name, to: 'descMetadata'

  # data_owner is the e-mail address of the colection's owner.
  delegate :private_data_owner, to: 'descMetadata'

  delegate :privacy_status, to: 'descMetadata'


  # ActiveFedora returns the value as an array, we need the first value
  def flat_name
    flat_short_name
  end

  # ActiveFedora returns the value as an array, we need the first value
  def flat_short_name
    self[:short_name].first
  end

  # ActiveFedora returns the value as an array, we need the first value
  def flat_uri
    self[:uri].first
  end

  # ActiveFedora returns the value as an array, we need the first value
  def flat_ownerEmail
    self[:private_data_owner].first
  end

  # ActiveFedora returns the value as an array, we need the first value
  def flat_private_data_owner
    self.flat_ownerEmail
  end

  # ---------------------------------------

  #
  # Get the data owner
  #
  def data_owner
    return User.find_by_user_key(private_data_owner)
  end

  #
  # Set the data owner
  #
  def set_data_owner_and_save(user)
    case user
      when String
        self.private_data_owner = user
      when User
        self.private_data_owner = user.email
      else
        self.private_data_owner = user.to_s
    end

    email = private_data_owner.first
    self.set_discover_users([email],self.discover_users)
    self.set_read_users([email],self.read_users)
    self.set_edit_users([email],self.edit_users)
    self.save

    self.items.each do |aItem|
      aItem.set_discover_users([email],aItem.discover_users)
      aItem.set_read_users([email],aItem.read_users)
      aItem.set_edit_users([email], aItem.edit_users)
      aItem.save

      aItem.documents.each do |aDocument|
        aDocument.set_discover_users([email], aDocument.discover_users)
        aDocument.set_read_users([email], aDocument.read_users)
        aDocument.set_edit_users([email], aDocument.edit_users)
        aDocument.save
      end
    end
    return self.private_data_owner
  end


  #
  # Find a collection using its uri
  #
  def Collection.find_by_uri(uri)
    return Collection.where(uri: uri).all
  end

  #
  # Find a collection using its short_name
  #
  def Collection.find_by_short_name(short_name)
    return Collection.where(short_name: short_name).all
  end

  def setCollectionList(collectionList)
    self.collectionList = collectionList
    self.save!
  end

  def setLicence(licence)
    unless licence.nil?
      licence = Licence.find(licence.to_s) unless licence.is_a? Licence
    end
    self.licence = licence
    self.save!
  end

  # Query of privacy status
  def private?
    self[:privacy_status]
  end

  # Query of privacy status
  def public?
    !self[:privacy_status]
  end

  #
  # Find collection by the given user that were not assigned to any Collection List
  #
  def self.find_by_owner_email_and_unassigned(userEmail)
    collections = Collection.find(:private_data_owner => userEmail)
    return collections.select{ |c| c.collectionList.nil? }
  end
end
