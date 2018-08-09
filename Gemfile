source 'https://rubygems.org'

ruby "2.1.4"
gem 'rails', '~> 3.2.18'
gem 'pg'

# Gems used only for assets and not required
# in production environments by default.
group :assets do
  gem 'sass-rails',   '~> 3.2.6'
  # sass must fix at 3.4.20
  gem 'sass', '3.4.20'
  gem 'coffee-rails', '~> 3.2.1'
  gem "therubyracer"
  gem 'uglifier', '2.7.2'
  gem 'turbo-sprockets-rails3'
end

gem "jquery-rails", "3.1.3"
gem 'jquery-ui-rails'

group :development, :test do
  gem "brakeman"
  gem "bundler-audit"
  gem "rspec-rails", '2.14.2'
  gem "factory_girl_rails"
  gem "quiet_assets"
  gem "capybara"
  gem "launchy"    # So you can do Then show me the page
end

group :development do
  # gem 'thin'
  gem 'puma'

  gem 'xray-rails'
  gem 'pry'
  gem 'pry-rails'
  gem 'zeus'
  gem "better_errors"
  gem "binding_of_caller"
  gem 'sextant'

  # Deployment tracker
  gem "create_deployment_record", git: 'https://github.com/IntersectAustralia/create_deployment_record.git'
end

group :test do
  # https://github.com/cucumber/cucumber-rails/blob/master/README.md
  # For Rails 3.x support, use version 1.4.5
  gem "cucumber-rails", "=1.4.5", :require => false
  gem 'database_cleaner'
  gem "shoulda"
  gem "simplecov", ">=0.3.8", :require => false
  gem 'simplecov-rcov'
  gem "poltergeist"
  # gem "selenium-webdriver"
  gem 'spreewald'
  gem "json-compare", '0.1.8'
  gem 'rspec-json_expectations', '~>2.0.0'
  # KL: 12/12
  gem 'test-unit', '~> 3.0'
end

# KL: for OAuth2
gem 'doorkeeper'

# KL
# gem 'rdf', '1.1.3'

gem "jsonpath"

gem 'clipboard-rails'
gem "haml"
gem "haml-rails"
gem "simple_form"

# 4.0.3 fix the "TypeError: element.select2 is not a function" issue
gem "select2-rails"

gem "devise", "~> 2.2.4"
gem "email_spec", :group => :test
gem "cancan"

# blacklight and hydra gems
#  KL: only load 4.2.1
# gem 'blacklight'
gem 'blacklight', "4.2.1"

gem 'hydra-head', "~>6.0.0"
gem 'jettywrapper'

gem "bootstrap-sass", "2.3.2.2"
gem 'activerecord-tableless'

gem 'stomp'
gem 'celluloid'
gem 'daemons'
gem 'activemessaging'

gem 'solrizer'
gem 'rsolr'
gem "xml-simple"
gem 'nokogiri'
gem 'mimemagic'
# gem for showing tabs on pages
gem "tabs_on_rails"
gem 'colorize'

# ruby json builder
gem 'rabl'
gem 'jbuilder'

# exception tracker
# gem 'whoops_rails_logger', git: 'https://github.com/IntersectAustralia/whoops_rails_logger.git'

gem 'linkeddata', '~> 1.0.0'
gem 'rdf-turtle'
gem 'rdf-sesame', git: 'https://github.com/ruby-rdf/rdf-sesame.git'
gem 'json_pure', '1.8.0'
gem 'json-ld'
gem 'sparql'

gem 'request_exception_handler'

# Capistrano stuff
gem 'rvm-capistrano', "~> 1"
gem 'capistrano', '2.15.4'
gem "capistrano_colors"

gem 'tinymce-rails'
# KL 13/12/2016
# gem 'rubyzip', '0.9.9'
gem 'rubyzip', '>= 1.0.0' # will load new rubyzip version
gem 'zip-zip'             # will load compatibility for old rubyzip API.
gem 'bagit'

gem 'google-analytics-rails'

gem 'json-jwt'
gem 'devise_aaf_rc_authenticatable', :git => 'https://github.com/IntersectAustralia/devise_aaf_rc_authenticatable'

gem 'keepass-password-generator'

gem "whenever", require: false

# KL: controller enhancement
gem 'kramdown'
gem 'simplemde-rails'
# file upload
# https://github.com/Phifo/jquery-fileupload-rails-carrierwave
gem 'jquery-fileupload-rails', '0.4.1'
gem 'file_validators'
# at this stage we're on rails 3, so use 0.11.0
gem 'carrierwave', "0.11.0"
gem 'mini_magick'
# gem 'rmagick', '~> 2.15', '>= 2.15.4'

# http://stackoverflow.com/questions/35893584/nomethoderror-undefined-method-last-comment-after-upgrading-to-rake-11
gem 'rake', '< 11.0'

# A gem to stream dynamically generated zip files from a rails application.
gem 'zipline'

# activerecord-import is a library for bulk inserting data using ActiveRecord.
gem "activerecord-import", ">= 0.2.0"

gem 'exception_notification'

#rest client for http post
gem 'rest-client'
