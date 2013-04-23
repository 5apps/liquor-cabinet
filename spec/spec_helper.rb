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

config_file = File.read(File.expand_path('../config.yml', File.dirname(__FILE__)))
config = YAML.load(config_file)[ENV['RACK_ENV']]
set :riak_config, config['riak'].symbolize_keys
set :bucket_config, config['buckets']

::Riak.disable_list_keys_warnings = true

def app
  LiquorCabinet
end

def storage_client
  @storage_client ||= ::Riak::Client.new(settings.riak_config)
end

def data_bucket
  @data_bucket ||= storage_client.bucket(settings.bucket_config['data'])
end

def auth_bucket
  @auth_bucket ||= storage_client.bucket(settings.bucket_config['authorizations'])
end

def directory_bucket
  @directory_bucket ||= storage_client.bucket(settings.bucket_config['directories'])
end

def binary_bucket
  @binary_bucket ||= storage_client.bucket(settings.bucket_config['binaries'])
end

def info_bucket
  @info_bucket ||= storage_client.bucket(settings.bucket_config['info'])
end

def purge_all_buckets
  [data_bucket, directory_bucket, auth_bucket, binary_bucket, info_bucket].each do |bucket|
    bucket.keys.each {|key| bucket.delete key}
  end
end

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
