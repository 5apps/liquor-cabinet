source "http://rubygems.org"

gem "sinatra"
gem "sinatra-contrib"
gem "riak-client"
gem "airbrake"

group :test do
  gem 'rake'
  gem 'purdytest', :require => false
  gem 'm'
end

group :staging, :production do
  gem "unicorn"
end
