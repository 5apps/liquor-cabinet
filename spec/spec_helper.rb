ENV["RACK_ENV"] = "test"

require 'rubygems'
require 'bundler'
Bundler.require

require_relative '../liquor-cabinet'
require 'minitest/autorun'
require 'rack/test'
require 'purdytest'
require "redis"
require "rest_client"
require "minitest/stub_any_instance"
require "ostruct"

def app
  LiquorCabinet
end

app.set :environment, :test

def wait_a_second
  now = Time.now.to_i
  while Time.now.to_i == now; end
end

def write_last_response_to_file(filename = "last_response.html")
  File.open(filename, "w") do |f|
    f.write last_response.body
  end
end

alias context describe

if app.settings.respond_to? :redis
  def redis
    @redis ||= Redis.new(app.settings.redis.symbolize_keys)
  end

  def purge_redis
    redis.keys("rs*").each do |key|
      redis.del key
    end
  end
end
