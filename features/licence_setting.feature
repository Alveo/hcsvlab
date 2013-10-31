Feature: Managing Collection Lists and Licences
  As a Data Owner, I want to create a Collection List,
  so I can associate a licence with multiple collections at once.

  Background:
    Given I have the usual roles and permissions
    Given I have users
      | email                       | first_name   | last_name |
      | data_owner@intersect.org.au | dataOwner    | One       |
    Given "data_owner@intersect.org.au" has role "data owner"
    Given I ingest "cooee:1-001" with id "hcsvlab:1"
    Given I ingest "auslit:adaessa" with id "hcsvlab:2"
    Given I ingest licences
    And I am logged in as "data_owner@intersect.org.au"
    And I am on the licences page

  @javascript
  Scenario: Verifying initial page data
    And I should see "There are no Collection Lists created."
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |                   | Add Licence |               |
      |cooee      |                   | Add Licence |               |
    And I click Add Licence for the 1st collection
    Then I should see "Creative Commons v3.0 BY-NC"
    And I should see "AusNC Terms of Use"


  @javascript
  Scenario: Creating an empty Collection List
    And I follow "Add selected to Collection list"
    And I follow "Create New Collection List"
    And I wait 2 seconds
    And I should see "Create New Collection list"
    And I fill in "Name" with "Collection List 1"
    And I press "Create Collections List"
    And I should see "You can not create an empty Collection List, please select at least one Collection."

  @javascript
  Scenario: Creating a Collection List with one Collection
    And I choose the 1st Collection in the list
    And I follow "Add selected to Collection list"
    And I follow "Create New Collection List"
    And I wait 2 seconds
    And I should see "Create New Collection list"
    And I fill in "Name" with "Collection List 1"
    And I press "Create Collections List"
    And The Collection Lists table should have
      |collection_list    | owner                       | licence     | licence_terms |
      |Collection List 1  | data_owner@intersect.org.au | Add Licence |               |
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |Collection List 1  |             |               |
      |cooee      |                   | Add Licence |               |

  @javascript
  Scenario: Creating a Collection List with all Collection
    When I check "allnonecheckbox"
    And I follow "Add selected to Collection list"
    And I follow "Create New Collection List"
    And I wait 2 seconds
    And I should see "Create New Collection list"
    And I fill in "Name" with "Collection List 1"
    And I press "Create Collections List"
    And The Collection Lists table should have
      |collection_list    | owner                       | licence     | licence_terms |
      |Collection List 1  | data_owner@intersect.org.au | Add Licence |               |
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |Collection List 1  |             |               |
      |cooee      |Collection List 1  |             |               |

  @javascript
  Scenario: Creating two collection lists with one collection each
    And I choose the 1st Collection in the list
    And I follow "Add selected to Collection list"
    And I follow "Create New Collection List"
    And I wait 2 seconds
    And I should see "Create New Collection list"
    And I fill in "Name" with "Collection List 1"
    And I press "Create Collections List"
    And The Collection Lists table should have
      |collection_list    | owner                       | licence     | licence_terms |
      |Collection List 1  | data_owner@intersect.org.au | Add Licence |               |
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |Collection List 1  |             |               |
      |cooee      |                   | Add Licence |               |
    Then I check "allnonecheckbox"
    And I follow "Add selected to Collection list"
    And I follow "Create New Collection List"
    And I wait 2 seconds
    And I should see "Create New Collection list"
    And I fill in "Name" with "Collection List 2"
    And I press "Create Collections List"
    And The Collection Lists table should have
      |collection_list    | owner                       | licence     | licence_terms |
      |Collection List 1  | data_owner@intersect.org.au | Add Licence |               |
      |Collection List 2  | data_owner@intersect.org.au | Add Licence |               |
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |Collection List 1  |             |               |
      |cooee      |Collection List 2  |             |               |

  @javascript
  Scenario: Creating two collection lists with the same name
    And I choose the 1st Collection in the list
    And I follow "Add selected to Collection list"
    And I follow "Create New Collection List"
    And I wait 2 seconds
    And I should see "Create New Collection list"
    And I fill in "Name" with "Collection List 1"
    And I press "Create Collections List"
    And The Collection Lists table should have
      |collection_list    | owner                       | licence     | licence_terms |
      |Collection List 1  | data_owner@intersect.org.au | Add Licence |               |
    Then I check "allnonecheckbox"
    And I follow "Add selected to Collection list"
    And I follow "Create New Collection List"
    And I wait 2 seconds
    And I should see "Create New Collection list"
    And I fill in "Name" with "Collection List 1"
    And I press "Create Collections List"
    Then I should see "Create New Collection list"
    And I should see "Collection list name already exists"
    Then I click "Close"
    And The Collection Lists table should have
      |collection_list    | owner                       | licence     | licence_terms |
      |Collection List 1  | data_owner@intersect.org.au | Add Licence |               |
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |Collection List 1  |             |               |
      |cooee      |                   | Add Licence |               |


  @javascript
  Scenario: Assign licence to a Collection
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |                   | Add Licence |               |
      |cooee      |                   | Add Licence |               |
    And I click Add Licence for the 1st collection
    And I follow "Creative Commons v3.0 BY-NC"
    Then The Collection table should have
      |collection |collection_list    | licence                     | licence_terms       |
      |austlit    |                   | Creative Commons v3.0 BY-NC | View Licence Terms  |
      |cooee      |                   | Add Licence                 |                     |
    And I should see "Successfully added licence to austlit"

  @javascript
  Scenario: Assign licence to a Collection List
    And I choose the 1st Collection in the list
    And I follow "Add selected to Collection list"
    And I follow "Create New Collection List"
    And I wait 2 seconds
    And I should see "Create New Collection list"
    And I fill in "Name" with "Collection List 1"
    And I press "Create Collections List"
    And The Collection Lists table should have
      |collection_list    | owner                       | licence     | licence_terms |
      |Collection List 1  | data_owner@intersect.org.au | Add Licence |               |
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |Collection List 1  |             |               |
      |cooee      |                   | Add Licence |               |
    Then I click Add Licence for the 1st collection list
    And I follow "Creative Commons v3.0 BY-NC"
    And The Collection Lists table should have
      |collection_list    | owner                       | licence                     | licence_terms       |
      |Collection List 1  | data_owner@intersect.org.au | Creative Commons v3.0 BY-NC | View Licence Terms  |
    And The Collection table should have
      |collection |collection_list    | licence                     | licence_terms       |
      |austlit    |Collection List 1  | Creative Commons v3.0 BY-NC | View Licence Terms  |
      |cooee      |                   | Add Licence                 |                     |

  @javascript
  Scenario: Remove a collection list
    And I choose the 1st Collection in the list
    And I follow "Add selected to Collection list"
    And I follow "Create New Collection List"
    And I wait 2 seconds
    And I should see "Create New Collection list"
    And I fill in "Name" with "Collection List 1"
    And I press "Create Collections List"
    And The Collection Lists table should have
      |collection_list    | owner                       | licence     | licence_terms |
      |Collection List 1  | data_owner@intersect.org.au | Add Licence |               |
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |Collection List 1  |             |               |
      |cooee      |                   | Add Licence |               |
    Then I click on the remove icon for the 1st collection list
    And The popup text should contain "Are you sure you want to remove the Collections List"
    Then I confirm the popup
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |                   | Add Licence |               |
      |cooee      |                   | Add Licence |               |

  @javascript
  Scenario: View licence terms of a Collection
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |                   | Add Licence |               |
      |cooee      |                   | Add Licence |               |
    And I click Add Licence for the 1st collection
    And I follow "Creative Commons v3.0 BY-NC"
    Then The Collection table should have
      |collection |collection_list    | licence                     | licence_terms       |
      |austlit    |                   | Creative Commons v3.0 BY-NC | View Licence Terms  |
      |cooee      |                   | Add Licence                 |                     |
    When I click View Licence Terms for the 1st collection
    Then I should see "THE WORK (AS DEFINED BELOW) IS PROVIDED UNDER THE TERMS OF THIS CREATIVE COMMONS PUBLIC LICENCE."

  @javascript
  Scenario: Create new licence and assign it to a collection
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |                   | Add Licence |               |
      |cooee      |                   | Add Licence |               |
    And I click Add Licence for the 1st collection
    And I follow "Create New"
    And I fill in "Licence name" with "Licence 1"
    And I fill in tiny_mce editor with "This is the text of Licence 1"
    And I press "Create"
    Then I should see "Licence created successfully"
    Then The Collection table should have
      |collection |collection_list    | licence        | licence_terms       |
      |austlit    |                   | Licence 1      | View Licence Terms  |
      |cooee      |                   | Add Licence    |                     |
    When I click View Licence Terms for the 1st collection
    Then I should see "This is the text of Licence 1"

  @javascript
  Scenario: Create duplicated licence
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |                   | Add Licence |               |
      |cooee      |                   | Add Licence |               |
    And I click Add Licence for the 1st collection
    And I follow "Create New"
    And I fill in "Licence name" with "Licence 1"
    And I fill in tiny_mce editor with "This is the text of Licence 1"
    And I press "Create"
    Then I should see "Licence created successfully"
    Then The Collection table should have
      |collection |collection_list    | licence        | licence_terms       |
      |austlit    |                   | Licence 1      | View Licence Terms  |
      |cooee      |                   | Add Licence    |                     |
    And I click Add Licence for the 1st collection
    And I follow "Create New"
    And I fill in "Licence name" with "Licence 1"
    And I fill in tiny_mce editor with "This is the text of Licence 1"
    And I press "Create"
    Then I should see "Licence name 'Licence 1' already exists"

  @javascript
  Scenario: Create licence with empty name
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |                   | Add Licence |               |
      |cooee      |                   | Add Licence |               |
    And I click Add Licence for the 1st collection
    And I follow "Create New"
    And I fill in "Licence name" with ""
    And I fill in tiny_mce editor with "This is the text of Licence 1"
    And I press "Create"
    Then I should see "Licence Name can not be blank"

  @javascript
  Scenario: Create licence with empty text
    And The Collection table should have
      |collection |collection_list    | licence     | licence_terms |
      |austlit    |                   | Add Licence |               |
      |cooee      |                   | Add Licence |               |
    And I click Add Licence for the 1st collection
    And I follow "Create New"
    And I fill in "Licence name" with "Licence 1"
    And I fill in tiny_mce editor with ""
    And I press "Create"
    Then I should see "Licence Text can not be blank"

  @javascript
  Scenario: Change a collection list's privacy status
    When I check "allnonecheckbox"
    And I follow "Add selected to Collection list"
    And I follow "Create New Collection List"
    And I wait 2 seconds
    And I fill in "Name" with "Collection List 1"
    And I press "Create Collections List"
    Then I click on the privacy remove icon for the 1st collection list
    Then I should see "Collection List 1 has been successfully marked as requiring personal approval"

  @javascript
  Scenario: Change a collection's privacy status
    Then I click on the privacy remove icon for the 1st collection
    Then I should see "austlit has been successfully marked as requiring personal approval"

  @javascript
  Scenario: Change a collection's privacy status with pending licence requests
    When I have users
      | email                       | first_name   | last_name |
      | researcher@intersect.org.au | researcher   | One       |
    And "researcher@intersect.org.au" has role "researcher"
    Then I click on the privacy remove icon for the 1st collection
    And I should see "austlit has been successfully marked as requiring personal approval"
    And there is a licence request for collection "austlit" by "researcher@intersect.org.au"
    Then I click on the privacy remove icon for the 1st collection
    And I should see "austlit has been successfully marked as public"
    And I am on the licence requests page
    Then I should see "No requests to display"

  @javascript
  Scenario: Change a collection list's privacy status with pending licence requests
    When I have users
      | email                       | first_name   | last_name |
      | researcher@intersect.org.au | researcher   | One       |
    And "researcher@intersect.org.au" has role "researcher"
    When I check "allnonecheckbox"
    And I follow "Add selected to Collection list"
    And I follow "Create New Collection List"
    And I wait 2 seconds
    And I fill in "Name" with "Collection List 1"
    And I check "collection_list_privacy_status"
    And I press "Create Collections List"
    And there is a licence request for collection list "Collection List 1" by "researcher@intersect.org.au"
    Then I click on the privacy remove icon for the 1st collection list
    And I should see "Collection List 1 has been successfully marked as public"
    And I am on the licence requests page
    Then I should see "No requests to display"