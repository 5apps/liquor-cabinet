source "https://rubygems.org"

gem "sinatra", "~> 2.2.0"
gem "sinatra-contrib", "~> 2.2.0"
gem "activesupport", "~> 6.1.0"
gem "redis", "~> 4.6.0"
gem "rest-client", "~> 2.1.0"
gem "aws-sigv4", "~> 1.0.0"
gem "mime-types"
gem "rainbows"

group :test do
  gem 'rake'
  gem 'rack-test'
  gem 'm'
  gem 'minitest'
  gem 'minitest-stub_any_instance'
  gem 'webmock'
end

group :staging, :production do
  gem "sentry-raven", require: false
end
