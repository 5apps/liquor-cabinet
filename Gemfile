source "https://rubygems.org"

gem "sinatra", "~> 2.2.0"
gem "sinatra-contrib", "~> 2.2.0"
gem "activesupport", "~> 6.1.0"
gem "rest-client", "~> 2.1.0"
gem "redis", "~> 4.6.0"
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
