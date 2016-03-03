source "https://rubygems.org"

gem "sinatra", '~> 1.4'
gem "sinatra-contrib"
gem "activesupport"
gem "riak-client", :github => "5apps/riak-ruby-client", :branch => "invalid_uri_error"
gem "fog-aws"
gem "rest-client"
gem "redis"
# Remove require when we can update to 3.0, which sets the new storage
# format to columnar by default. Increases performance
gem "mime-types", "~> 2.99", require: 'mime/types/columnar'

group :test do
  gem 'rake'
  gem 'purdytest', :require => false
  gem 'm'
  gem 'minitest-stub_any_instance'
end

group :staging, :production do
  gem "rainbows"
  gem "sentry-raven", require: false
end
