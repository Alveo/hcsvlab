class User < ActiveRecord::Base
# Connects this user object to Hydra behaviors.
  include Hydra::User
# Connects this user object to Blacklights Bookmarks.
  include Blacklight::User
# Include devise modules
  devise :database_authenticatable, :registerable, :lockable, :recoverable, :trackable, :validatable, :timeoutable, :token_authenticatable, :aaf_rc_authenticatable

  belongs_to :role
  has_many :user_sessions, dependent: :destroy
  has_many :user_searches, dependent: :destroy
  has_many :item_lists, dependent: :destroy
  has_many :user_licence_agreements, dependent: :destroy
  has_many :user_licence_requests, dependent: :destroy
  has_many :user_annotations, dependent: :destroy
  has_many :collection_lists, inverse_of: :owner, foreign_key: :owner_id, dependent: :destroy
  has_many :collections, inverse_of: :owner, foreign_key: :owner_id, dependent: :destroy
  has_many :licences, inverse_of: :owner, foreign_key: :owner_id
  has_many :document_audits, dependent: :destroy

# Setup accessible attributes (status/approved flags should NEVER be accessible by mass assignment)
  attr_accessible :email, :password, :password_confirmation, :first_name, :last_name, :status, :role_id

  validates :first_name, presence: true
  validates :last_name, presence: true
  validates :status, presence: true
  validates :email, presence: true, uniqueness: {case_sensitive: false}

  with_options :if => :password_required? do |v|
    v.validates :password, :password_format => true
  end

  before_validation :initialize_status

  scope :pending_approval, where(:status => 'U').order(:email)

  scope :approved, where(:status => 'A').order(:email)
  scope :deactivated_or_approved, where("status = 'D' or status = 'A' ").order(:email)
  scope :approved_superusers, joins(:role).merge(User.approved).merge(Role.superuser_roles)
  scope :approved_data_owners, joins(:role).merge(User.approved).merge(Role.data_owner_roles)
  scope :approved_researchers, joins(:role).merge(User.approved).merge(Role.researcher_roles)

  after_initialize do |user|
    # The after_initialize callback will be called whenever an Active Record object is
    # instantiated, either by directly using new or when a record is loaded from the database.
    # It can be useful to avoid the need to directly override your Active Record initialize
    # method.
    #
    # http://guides.rubyonrails.org/active_record_callbacks.html#after-initialize-and-after-find
    if user.id.nil?
      user.status = 'U'
    end
  end

# Override Devise active for authentication method so that users must be approved before being allowed to log in
# https://github.com/plataformatec/devise/wiki/How-To:-Require-admin-to-activate-account-before-sign_in
  def active_for_authentication?
    super && approved?
  end

  def aaf_logged_in?(aaf_email)
    aaf_email.present? && self.email.eql?(aaf_email)
  end

  def aaf_rc_before_save
    self.status = "U"
    generate_temp_password
    self.aaf_registered = true
    notify_admin_by_email
  end

  def after_aaf_rc_authentication
    raise Exception.new('Unauthorized') unless approved?
  end

# Override Devise method so that user is actually notified right after the third failed attempt.
  def attempts_exceeded?
    self.failed_attempts >= self.class.maximum_attempts
  end

# Overrride Devise method so we can check if account is active before allowing them to get a password reset email
  def send_reset_password_instructions
    if approved?
      generate_reset_password_token!
      Notifier.reset_password_instructions(self).deliver
    else
      if pending_approval? or deactivated?
        Notifier.notify_user_that_they_cant_reset_their_password(self).deliver
      end
    end
  end

# Custom method overriding update_with_password so that we always require a password on the update password action
# Devise expects the update user and update password to be the same screen so accepts a blank password as indicating that
# the user doesn't want to change it
  def update_password(params={})
    current_password = params.delete(:current_password)

    result = if valid_password?(current_password)
               update_attributes(params)
             else
               self.errors.add(:current_password, current_password.blank? ? :blank : :invalid)
               self.attributes = params
               false
             end

    clean_up_passwords
    result
  end

# Generates and sets user password
  def generate_temp_password
    password = KeePass::Password.generate('uldsA{5}', :remove_lookalikes => true)
    self.reset_password!(password, password)
  end

# Override devise method that resets a forgotten password, so we can clear locks on reset
  def reset_password!(new_password, new_password_confirmation)
    self.password = new_password
    self.password_confirmation = new_password_confirmation
    clear_reset_password_token if valid?
    if valid?
      unlock_access! if access_locked?
    end
    save
  end

  def approved?
    self.status == 'A'
  end

  def pending_approval?
    self.status == 'U'
  end

  def deactivated?
    self.status == 'D'
  end

  def rejected?
    self.status == 'R'
  end

  # To judge whether current user is visitor
  # Visitor has no user id
  def is_visitor?
    return self.id.nil?
  end

  def deactivate
    self.status = 'D'
    save!(:validate => false)
  end

  def activate
    self.status = 'A'
    save!(:validate => false)
  end

  def is_superuser?
    self.role == Role.find_by_name(Role::SUPERUSER_ROLE)
  end

  def is_researcher?
    self.role == Role.find_by_name(Role::RESEARCHER_ROLE)
  end

  def is_data_owner?
    self.role == Role.find_by_name(Role::DATA_OWNER_ROLE)
  end

  def approve_access_request
    self.status = 'A'
    save!(:validate => false)

    # send an email to the user
    if self.aaf_registered
      generate_temp_password
      Notifier.notify_aaf_user_approval_and_password(self, password).deliver
    else
      Notifier.notify_user_of_approved_request(self).deliver
    end
  end

  def reject_access_request
    self.status = 'R'
    save!(:validate => false)

    # send an email to the user
    Notifier.notify_user_of_rejected_request(self).deliver
  end

  def notify_admin_by_email
    Notifier.notify_superusers_of_access_request(self).deliver
  end

  def check_number_of_superusers(id, current_user_id)
    current_user_id != id.to_i or User.approved_superusers.length >= 2
  end

  def self.get_superuser_emails
    approved_superusers.collect { |u| u.email }
  end

  def full_name
    "#{first_name} #{last_name}".strip
  end

  def cannot_own_data?
    !((Role.superuser_roles + Role.data_owner_roles).include? self.role)
  end

  def groups
    if is_visitor?
      # visitor, no user id
      sql = "" "
        SELECT c.name || '-' || ula_cl.access_type AS group_name
        FROM collections c INNER JOIN
          (SELECT cl.id as collection_list_id, ula.access_type as access_type
          FROM collection_lists cl INNER JOIN user_licence_agreements ula
          ON cl.name=ula.name WHERE ula.collection_type='collection_list') ula_cl
        ON c.collection_list_id=ula_cl.collection_list_id
        UNION
        SELECT c.name || '-' || ula.access_type as group_name
        FROM user_licence_agreements ula
        INNER JOIN collections c
        ON ula.name=c.name
        WHERE ula.collection_type='collection';
      " ""
    else
      # logged in user with user id
      sql = "" "
        SELECT c.name || '-' || ula_cl.access_type AS group_name
        FROM collections c INNER JOIN
          (SELECT cl.id as collection_list_id, ula.access_type as access_type
          FROM collection_lists cl INNER JOIN user_licence_agreements ula
          ON cl.name=ula.name WHERE ula.collection_type='collection_list' AND ula.user_id=#{self.id}) ula_cl
        ON c.collection_list_id=ula_cl.collection_list_id
        UNION
        SELECT c.name || '-' || ula.access_type as group_name
        FROM user_licence_agreements ula
        INNER JOIN collections c
        ON ula.name=c.name
        WHERE ula.collection_type='collection' AND ula.user_id=#{self.id};
      " ""
    end

    ActiveRecord::Base.connection.execute(sql).field_values('group_name')
  end

#
# Adds the permission level defined by 'accessType' to the given 'collection' or 'collection_list'
#
  def add_agreement_to_collection(collection, accessType, type='collection')
    ula = UserLicenceAgreement.new
    ula.access_type = accessType
    ula.name = collection.name
    ula.collection_type = type
    ula.licence_id = collection.licence_id
    ula.user = self
    ula.save
  end

#
# Does this user have the given permission level (defined by 'accessType')
# for the given 'collection'. If 'exact' is true, then it must be exactly
# that permission, if false then look for that permission or better.
#
# TODO refactor this

  def has_agreement_to_collection?(collection, access_type, exact=false)
    # if the user is the owner of the collection, then he/she does have access.
    # think about visitor with nil id
    unless self.id.nil?
      if collection.owner_id.eql?(self.id)
        return true
      end
    else
      return false
    end


    access_types = UserLicenceAgreement::type_or_higher(access_type) unless exact

    col_list = collection.collection_list
    if col_list.present?
      self.user_licence_agreements.where(name: col_list.name, collection_type: 'collection_list', access_type: access_types).count > 0
    else
      self.user_licence_agreements.where(name: collection.name, collection_type: 'collection', access_type: access_types).count > 0
    end
  end

# think about visitor with nil id
  def has_requested_collection?(id)
    user_licence_requests.where(:request_id => id.to_s).count > 0 unless id.nil?
  end

# think about visitor with nil id
  def requested_collection(id)
    user_licence_requests.find_by_request_id(id.to_s) unless id.nil?
  end

#
# Removes the permission level defined by 'accessType' to the given 'collection'
#
  def remove_agreement_to_collection(collection, access_type)
    self.user_licence_agreements.where(name: collection.name, collection_type: 'collection', access_type: access_type).delete_all
  end

# think about visitor with nil id
  def accept_licence_request(id)
    unless id.nil?
      if has_requested_collection?(id)
        requested_collection(id).destroy
      end
    end
  end

# ===========================================================================
# Licence management
# ===========================================================================

#
# Return all my licensing information. The form of this is an array of
# Hashes. Each Hash contains a Collection or CollectionList and the
# information for it. Returns an empty Array (rather than nil) if there is no
# licensing information.
#
  def get_all_licence_info(include_own = false)
    result = []

    CollectionList.all.each do |list|
      result << get_collection_list_licence_info(list) if can_see_collection_list(list)
    end

    # not show DRAFT collections
    Collection.where("status != 'DRAFT'").each do |coll|
      result << get_collection_licence_info(coll) if can_see_collection(coll) && coll.collection_list.nil?
    end

    unless include_own
      result = result.reject { |elt|
        elt[:state] == :owner
      }
    end

    return result
  end

  def get_collection_list_licence_info(list)
    if list.owner_id == id
      # I am the owner of this collection.
      state = :owner
    elsif self.has_requested_collection?(list.id) and !self.requested_collection(list.id).approved
      state = :waiting
      request = self.requested_collection(list.id)
    elsif self.has_requested_collection?(list.id) and self.requested_collection(list.id).approved
      state = :approved
      request = self.requested_collection(list.id)
    elsif !self.has_agreement_to_collection?(list.collections.first, UserLicenceAgreement::DISCOVER_ACCESS_TYPE) and list.private?
      state = :unapproved
    elsif !self.has_agreement_to_collection?(list.collections.first, UserLicenceAgreement::DISCOVER_ACCESS_TYPE) and list.is_public?
      state = :not_accepted
    elsif self.has_agreement_to_collection?(list.collections.first, UserLicenceAgreement::DISCOVER_ACCESS_TYPE)
      state = :accepted
    else
      state = :not_accepted
    end
    return {:item => list,
            :type => :collection_list,
            :state => state,
            :state_label => get_name_for_state(state),
            :actions => get_actions_for_state(state),
            :request => request}
  end

  def get_collection_licence_info(coll)
    if coll.owner == self
      # I, like, totally data own this collection.
      state = :owner
    elsif self.has_requested_collection?(coll.id) and !self.requested_collection(coll.id).approved
      state = :waiting
      request = self.requested_collection(coll.id)
    elsif self.has_requested_collection?(coll.id) and self.requested_collection(coll.id).approved
      state = :approved
      request = self.requested_collection(coll.id)
    elsif !self.has_agreement_to_collection?(coll, UserLicenceAgreement::DISCOVER_ACCESS_TYPE) and coll.private?
      state = :unapproved
    elsif !self.has_agreement_to_collection?(coll, UserLicenceAgreement::DISCOVER_ACCESS_TYPE)
      state = :not_accepted
    elsif self.has_agreement_to_collection?(coll, UserLicenceAgreement::DISCOVER_ACCESS_TYPE)
      state = :accepted
    else
      state = :not_accepted
    end
    return {:item => coll,
            :type => :collection,
            :state => state,
            :state_label => get_name_for_state(state),
            :actions => get_actions_for_state(state),
            :request => request}
  end

  def get_name_for_state(state)
    case state
      when :unapproved
        return "Unapproved"
      when :waiting
        return "Awaiting Approval"
      when :rejected
        return "Rejected"
      when :approved
        return "Approved"
      when :accepted
        return "Accepted"
      when :not_accepted
        return "Not Accepted"
      when :owner
        return "Owner"
      else
        return "unknown"
    end
  end

  def get_actions_for_state(state)
    case state
      when :unapproved
        return %i(view viewForRequest)
      when :waiting
        return %i(view cancel)
      when :rejected
        return %(viewForRequest)
      when :approved
        return %i(viewForAcceptance)
      when :accepted
        return %i(view)
      when :not_accepted
        return %i(viewForAcceptance)
#        return %i(viewForAcceptance view cancel viewForRequest)
      else
        return []
    end
  end

  def can_see_collection(coll)
    # TODO: (DC) check visibility of collections properly (or remove completely if we end up doing it by another mechanism)
    return false if coll.licence.nil?
    return true
  end

  def can_see_collection_list(coll)
    # TODO: (DC) check visibility of collection lists properly (or remove completely if we end up doing it by another mechanism)
    return false if coll.licence.nil?
    return true
  end

# end of Licence Management
# -------------------------

  private

  def initialize_status
    # initialised status as 'U'
    self.status = "U" unless self.status
  end

  def User::reset_pk_seq
    ActiveRecord::Base.connection.reset_pk_sequence!(User.table_name)
  end
end
