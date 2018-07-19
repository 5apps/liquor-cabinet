source "https://rubygems.org"

gem "sinatra", "= 2.0.2"
gem "sinatra-contrib", "= 2.0.2"
gem "activesupport"
gem "rest-client", "~> 2.1.0.rc1" # Fixes a memory leak in Ruby 2.4
gem "redis"
# Remove require when we can update to 3.0, which sets the new storage
# format to columnar by default. Increases performance
gem "mime-types"

group :test do
  gem 'rake'
  gem 'rack-test'
  gem 'purdytest', :require => false
  gem 'm'
  gem 'minitest-stub_any_instance'
  gem 'webmock'
end

group :staging, :production do
  gem "rainbows"
  gem "sentry-raven", require: false
end
