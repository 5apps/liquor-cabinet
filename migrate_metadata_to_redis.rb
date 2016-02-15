#!/usr/bin/env ruby

require "rest_client"
require "redis"

class Migrator

  attr_accessor :username, :token, :base_url

  def initialize(username, token)
    @username = username
    @token = token
    @base_url = "https://storage.5apps.com"
  end

  def configure_redis(redis_config)
    @redis_config = redis_config
  end

  def root_url
    "#{@base_url}/#{@username}"
  end

  def headers
    {"authorization" => "Bearer #{@token}"}
  end

  def is_dir?(name)
    name[-1] == "/"
  end

  def url_for(directory, parent_directory="")
    # base_path = [root_url, parent_directory].join("/")
    "#{root_url}#{parent_directory}#{directory}"
  end

  def migrate
    work_on_dir("", "/")
  end

  def work_on_dir(directory, parent_directory)
    url = url_for(directory, parent_directory)

    # puts "work on dir: #{url}"

    response = RestClient.get(url, headers)
    listing = JSON.parse(response.body)

    timestamp = (Time.now.to_f * 1000).to_i

    if listing["items"].any?
      items = listing["items"]
      items.each do |item, data|
        if is_dir? item
          save_directory_data("#{parent_directory}#{directory}", item, data, timestamp)

          # get dir listing and repeat
          work_on_dir(item, "#{parent_directory}#{directory}")
        else
          save_document_data("#{parent_directory}#{directory}", item, data, timestamp)
        end

        add_item_to_parent_dir("#{parent_directory}#{directory}", item)
      end
    end
  end

  def add_item_to_parent_dir(dir, item)
    key = "rs_meta:#{username}:#{parent_directory_for(dir)}:items"
    # puts "adding item #{item} to #{key}"
    redis.sadd key, item
  end

  def save_directory_data(dir, item, data, timestamp)
    key = "rs_meta:#{username}:#{dir.gsub(/^\//, "")}#{item}"
    metadata = {etag: data["ETag"], modified: timestamp}

    # puts "metadata for dir #{key}: #{metadata}"
    redis.hmset(key, *metadata)
  end

  def save_document_data(dir, item, data, timestamp)
    key = "rs_meta:#{username}:#{dir.gsub(/^\//, "")}#{item}"
    metadata = {
      etag: data["ETag"],
      size: data["Content-Length"],
      type: data["Content-Type"],
      modified: timestamp
    }
    # puts "metadata for document #{key}: #{metadata}"
    redis.hmset(key, *metadata)
  end

  def parent_directory_for(directory)
    return directory if directory == "/"

    return directory[0..directory.rindex("/")].gsub(/^\//, "")
  end

  def redis
    @redis ||= Redis.new(@redis_config)
  end

end

username = ARGV[0]
token = ARGV[1]

migrator = Migrator.new username, token
migrator.configure_redis({host: "localhost", port: 6379})

migrator.migrate





