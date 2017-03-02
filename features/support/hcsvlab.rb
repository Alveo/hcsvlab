# IMPORTANT: This file is generated for hcsvlab instead of editing env.rb, which is generated by cucumber-rails.
# Below code segment is moved from previous env.rb, which added by previous developer manually.

require 'simplecov'
require 'simplecov-rcov'

# disable code coverage
ENV["NO_COVERAGE"] = 'true'

SimpleCov.formatter = SimpleCov::Formatter::RcovFormatter
SimpleCov.start 'rails' unless ENV["NO_COVERAGE"]

require 'cucumber/rspec/doubles'

Capybara.match = :prefer_exact

require 'capybara/poltergeist'

 # for spreewald's table comparison steps
require 'spreewald/table_steps'

Capybara.javascript_driver = :poltergeist

def set_html_request
  begin
    Capybara.current_session.driver.header 'Accept', 'text/html'
  rescue
  end
end