source "http://rubygems.org"

gem "sinatra"
gem "sinatra-contrib"
gem "activesupport"
gem "riak-client"

group :test do
  gem 'rake'
  gem 'purdytest', :require => false
  gem 'm'
end

group :staging, :production do
  gem "unicorn"
end
