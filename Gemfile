source "http://rubygems.org"

unless @backend = ENV['BACKEND']
  $stderr.puts "WARNING: No BACKEND set. Defaulting to 'all'."
  @backend = 'all'
end

def backend_gem(backend, *gem_args)
  if @backend == 'all' || @backend == backend.to_s
    gem(*gem_args)
  end
end

gem "sinatra"
gem "sinatra-contrib"

gem 'haml'

backend_gem :riak, "riak-client"
backend_gem :couchdb, "couchrest"

gem "airbrake"

group :test do
  gem 'rake'
  gem 'purdytest', :require => false
  gem RUBY_VERSION > '1.9' ? 'ruby-debug19' : 'ruby-debug'
end
