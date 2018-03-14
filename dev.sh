#!/bin/sh

# https://blog.phusion.nl/2017/10/13/why-ruby-app-servers-break-on-macos-high-sierra-and-what-can-be-done-about-it/
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
RAILS_ENV=development
apache-activemq-5.8.0/bin/activemq stop
apache-activemq-5.8.0/bin/activemq start
rake jetty:start a13g:start_pollers
#rake jetty:start
#bash rails_puma.sh
rails s

