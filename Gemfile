source "http://rubygems.org"

require File.expand_path('lib/configuration.rb', File.dirname(__FILE__))

ENV['RACK_ENV'] ||= 'development'

extend Configuration

gem "sinatra"
gem "sinatra-contrib"

gem 'haml'

case config['backend']
when 'riak'
  gem "riak-client"
when 'couchdb'
  gem "couchrest"
else
  $stderr.puts "WARNING: No backend set in config, not loading any backend-specific gems."
end

if config['airbrake']
  gem "airbrake"
end

group :test do
  gem 'rake'
  gem 'purdytest', :require => false
  gem RUBY_VERSION > '1.9' ? 'ruby-debug19' : 'ruby-debug'
end
