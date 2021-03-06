# -*- encoding : utf-8 -*-
Then /^I should see the applied facet "([^\"]*)" with the value "([^\"]*)"$/ do |filter, text|
  page.should have_selector(".facet_limit")
  page.should have_selector("h5", :text => filter)
  page.should have_selector("span.selected", :text => text)
end

Then /^I should see the facet "([^\"]*)" with the value "([^\"]*)"$/ do |filter, text|
  page.should have_selector(".facet_limit")
  page.should have_selector("h5", :text => filter)
  page.should have_selector("a.label", :text => text)
end

Then /^the facet "([^\"]+)" should display$/ do |filter|
  page.should have_selector(".facet_limit")
  page.should have_selector("h5", :text => filter)
end

