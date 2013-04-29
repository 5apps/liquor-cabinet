require 'rubygems'
require 'bundler'
Bundler.require

require_relative '../liquor-cabinet'
require 'minitest/autorun'
require 'rack/test'
require 'purdytest'
require 'riak'

ENV["RACK_ENV"] = "test"

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

if app.settings.riak
  ::Riak.disable_list_keys_warnings = true

  def client
    @client ||= ::Riak::Client.new(:host => app.settings.riak['host'],
                                   :http_port => app.settings.riak['http_port'])
  end

  def data_bucket
    @data_bucket ||= client.bucket(app.settings.riak['buckets']['data'])
  end

  def auth_bucket
    @auth_bucket ||= client.bucket(app.settings.riak['buckets']['authorizations'])
  end

  def directory_bucket
    @directory_bucket ||= client.bucket(app.settings.riak['buckets']['directories'])
  end

  def binary_bucket
    @binary_bucket ||= client.bucket(app.settings.riak['buckets']['binaries'])
  end

  def opslog_bucket
    @opslog_bucket ||= client.bucket(app.settings.riak['buckets']['opslog'])
  end

  def purge_all_buckets
    [data_bucket, directory_bucket, auth_bucket, binary_bucket, opslog_bucket].each do |bucket|
      bucket.keys.each {|key| bucket.delete key}
    end
  end
end
