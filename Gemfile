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
backend_gem :riak, "riak-client"
backend_gem :couchdb, "couchrest"

gem 'haml'

group :test do
  gem 'rake'
  gem 'purdytest', :require => false
end
