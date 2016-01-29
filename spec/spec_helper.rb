ENV["RACK_ENV"] = "test"

require 'rubygems'
require 'bundler'
Bundler.require

require_relative '../liquor-cabinet'
require 'minitest/autorun'
require 'rack/test'
require 'purdytest'
require 'riak'
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

def redis
  @redis ||= Redis.new(host: app.settings.redis["host"], port: app.settings.redis["port"])
end

def purge_redis
  redis.keys("rs_*").each do |key|
    redis.del key
  end
end

if app.settings.respond_to? :riak
  ::Riak.disable_list_keys_warnings = true

  def client
    @client ||= ::Riak::Client.new(:host => app.settings.riak['host'],
                                   :http_port => app.settings.riak['http_port'])
  end

  def data_bucket
    @data_bucket ||= begin
                       bucket = client.bucket(app.settings.riak['buckets']['data'])
                       bucket.allow_mult = false
                       bucket
                     end
  end

  def directory_bucket
    @directory_bucket ||= begin
                            bucket = client.bucket(app.settings.riak['buckets']['directories'])
                            bucket.allow_mult = false
                            bucket
                          end
  end

  def auth_bucket
    @auth_bucket ||= begin
                       bucket = client.bucket(app.settings.riak['buckets']['authorizations'])
                       bucket.allow_mult = false
                       bucket
                     end
  end

  def opslog_bucket
    @opslog_bucket ||= begin
                         bucket = client.bucket(app.settings.riak['buckets']['opslog'])
                         bucket.allow_mult = false
                         bucket
                       end
  end

  def cs_credentials
    @cs_credentials ||= begin
                          credentials = File.read(app.settings.riak['riak_cs']['credentials_file'])
                          JSON.parse(credentials)
                        end
  end

  def cs_client
    @cs_client ||= Fog::Storage.new({
      :provider                 => 'AWS',
      :aws_access_key_id        => cs_credentials['key_id'],
      :aws_secret_access_key    => cs_credentials['key_secret'],
      :endpoint                 => app.settings.riak['riak_cs']['endpoint']
    })
  end

  def cs_binary_bucket
    @cs_binary_bucket ||= cs_client.directories.create(:key => app.settings.riak['buckets']['cs_binaries'])
  end

  def purge_all_buckets
    [data_bucket, directory_bucket, auth_bucket, opslog_bucket].each do |bucket|
      bucket.keys.each {|key| bucket.delete key}
    end

    cs_binary_bucket.files.each do |file|
      file.destroy
    end
  end
end
