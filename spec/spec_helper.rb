require 'rubygems'
require 'bundler'
Bundler.require

require_relative '../liquor-cabinet'
require 'minitest/autorun'
require 'rack/test'
require 'purdytest'
require 'riak'

set :environment, :test
ENV["RACK_ENV"] = "test"

config = File.read(File.expand_path('../config.yml', File.dirname(__FILE__)))
riak_config = YAML.load(config)[ENV['RACK_ENV']]['riak'].symbolize_keys
set :riak_config, riak_config

::Riak.disable_list_keys_warnings = true
::Riak.url_decoding = true

def app
  LiquorCabinet
end

def storage_client
  @storage_client ||= ::Riak::Client.new(settings.riak_config)
end

def data_bucket
  @data_bucket ||= storage_client.bucket("user_data")
end

def auth_bucket
  @auth_bucket ||= storage_client.bucket("authorizations")
end

def directory_bucket
  @directory_bucket ||= storage_client.bucket("rs_directories")
end

def purge_all_buckets
  [data_bucket, directory_bucket, auth_bucket].each do |bucket|
    bucket.keys.each {|key| bucket.delete key}
  end
end

def wait_a_second
  now = Time.now.to_i
  while Time.now.to_i == now; end
end

alias context describe
