source "https://rubygems.org"

gem "sinatra", '~> 1.4'
gem "sinatra-contrib"
gem "activesupport", '~> 3.2'
gem "riak-client", :github => "5apps/riak-ruby-client", :branch => "invalid_uri_error"
gem "fog"
gem "rest-client"
gem "redis"

group :test do
  gem 'rake'
  gem 'purdytest', :require => false
  gem 'm'
end

group :staging, :production do
  gem "rainbows"
  gem "sentry-raven"
end
