When /^"(.*)" has item lists$/ do |email, table|
  user = User.find_by_email!(email)
  table.hashes.each do |attributes|
    user.item_lists.create(attributes)
  end
end

When /^the item list "(.*)" should have (\d+) item(?:s)?$/ do |list_name, number|
  list = ItemList.find_by_name(list_name)
  list.get_item_handles.count.should eq(number.to_i)
end

When /^the item list "(.*)" should contain handles$/ do |list_name, table|
  list = ItemList.find_by_name(list_name)
  handles = list.get_item_handles
  table.hashes.each do |attributes|
    handles.include?(attributes[:handle]).should eq(true)
  end
end

When /^the item list "(.*)" has items (.*)$/ do |list_name, ids|
  list = ItemList.find_by_name(list_name)
  list.add_items(ids.split(", "))
end

Given(/^the item list "(.*?)" has (\d+) text documents$/) do |list_name, n|
  items = []
  file_paths = []
  n = n.to_i
  (0...n).each { |i| 
    filename = "file_#{i}.txt"
    documents = [FactoryGirl.create(:document, file_name: filename, file_path: filename)]
    items << FactoryGirl.create(:item, handle: "corpus:item_#{i}", documents: documents)
    file_paths << filename
  }
  ItemList.find_by_name(list_name).items = items
end

Given(/^the item list "(.*?)" has (\d+) items with two remote documents each$/) do |list_name, n|
  items = []
  handle_mapping = {}
  n = n.to_i
  (0...n).each { |i| 
    documents = []
    filepaths = []
    filename = "file_#{i}.txt"
    filepath = "http://www.example.com/file_#{i}.txt"
    handle = "corpus_item_#{i}"
    documents << FactoryGirl.create(:document, file_name: filename, file_path: filepath)
    
    filename = "file_#{i}"
    filepath = "http://www.example.com/file_#{i}"
    documents << FactoryGirl.create(:document, file_name: filename, file_path: filepath)

    items << FactoryGirl.create(:item, handle: "corpus:item_#{i}", documents: documents)
    handle_mapping[filename] = {handle: handle, files: [filepaths]}
  }
  ItemList.find_by_name(list_name).items = items
  Item::DownloadItemsHelper::DownloadItemsInFormat.any_instance.stub(:get_filenames_from_item_results).and_return(handle_mapping)
end

When(/^I filter by "(.*?)"$/) do |extension|
  page.find("//input[value='#{extension}']").set(true)
end


And /^I follow the delete icon for item list "(.*)"$/ do |list_name|
  list = ItemList.find_by_name(list_name)
  find("#delete_item_list_#{list.id}").click
end

Then /^concordance search for "(.*)" in item list "(.*)" should show this results$/ do |term, list_name, table|
  list = ItemList.find_by_name(list_name)
  list.set_current_user(@current_user)
  list.set_current_ability(Ability.new(@current_user))
  result = list.doConcordanceSearch(term)
  highlightings = result[:highlighting]
  totalMatches = highlightings.inject(0) { |sum, highlighting| sum + highlighting[1][:matches].length }
  countMatches = 0
  table.hashes.each do |attributes|
    requestedMatch = attributes[:textBefore].strip()
    requestedMatch = requestedMatch + "<span class='highlighting'>#{attributes[:textHighlighted]}</span>"
    requestedMatch = requestedMatch + attributes[:textAfter].strip()

    highlightings.each do |docId, matches|
      if (!matches[:title].eql?(attributes[:documentTitle]))
        next
      end
      matches[:matches].each do |aMatch|
        retrievedMatch = aMatch[:textBefore].strip()
        retrievedMatch = retrievedMatch + aMatch[:textHighlighted].strip()
        retrievedMatch = retrievedMatch + aMatch[:textAfter].strip()

        countMatches = countMatches + 1 if requestedMatch.eql?(retrievedMatch)
      end

    end
  end
  countMatches.should eq(totalMatches)
end

Then /^concordance search for "(.*)" in item list "(.*)" should show not matches found message$/ do |term, list_name|
  list = ItemList.find_by_name(list_name)
  list.set_current_user(@current_user)
  list.set_current_ability(Ability.new(@current_user))

  result = list.doConcordanceSearch(term)
  result[:matching_docs].should eq(0)
end

Then /^concordance search for "(.*)" in item list "(.*)" should show error$/ do |term, list_name|
  list = ItemList.find_by_name(list_name)
  list.set_current_user(@current_user)
  list.set_current_ability(Ability.new(@current_user))

  result = list.doConcordanceSearch(term)
  result[:error].empty?.should eq(false)
end




Then /^frequency search for "(.*)" in item list "(.*)" should show this results$/ do |term, list_name, table|
  list = ItemList.find_by_name(list_name)
  list.set_current_user(@current_user)
  list.set_current_ability(Ability.new(@current_user))

  field = find_field("Facet")
  result = list.doFrequencySearch(term, field.value)

  result[:status].should eq("OK")
  table.hashes.each do |attributes|
    result[:data][attributes[:facetValue]].should_not eq (nil)
    result[:data][attributes[:facetValue]][:num_docs].to_s.should eq(attributes[:matchingDocuments])
    result[:data][attributes[:facetValue]][:total_docs].to_s.should eq(attributes[:totalDocs])
    result[:data][attributes[:facetValue]][:num_occurrences].to_s.should eq(attributes[:termOccurrences])
    result[:data][attributes[:facetValue]][:total_words].to_s.should eq(attributes[:totalWords])

  end
end

Then /^frequency search for "(.*)" in item list "(.*)" should show error$/ do |term, list_name|
  list = ItemList.find_by_name(list_name)
  list.set_current_user(@current_user)
  list.set_current_ability(Ability.new(@current_user))

  field = find_field("Facet")
  result = list.doFrequencySearch(term, field.value)
  result[:status].should eq("INPUT_ERROR")
end

Then(/^I should get the API config file for "(.*?)"$/) do |user|
  page.response_headers['Content-Disposition'].should include("filename=\"#{PROJECT_PREFIX_NAME}.config\"")
  page.response_headers['Content-Disposition'].should include("attachment")

  page.body.should eq('{"base_url":"http://www.example.com/","apiKey":"' + User.find_by_email(user).authentication_token + '","cacheDir":"wrassp_cache"}
')
end