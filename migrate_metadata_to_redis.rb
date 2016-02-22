#!/usr/bin/env ruby

require "rest_client"
require "redis"
require "yaml"

class Migrator

  attr_accessor :username, :base_url, :swift_host, :swift_token,
                :environment, :dry_run, :logging, :settings

  def initialize(username)
    @username = username

    @environment = ENV["ENVIRONMENT"] || "staging"
    @settings = YAML.load(File.read('config.yml'))[@environment]
    @swift_host = @settings["swift"]["host"]
    @swift_token = File.read("tmp/swift_token.txt")

    @dry_run = false # disables writing anything to Redis when true
    @logging = true
  end

  def root_url
    "#{@base_url}/#{@username}"
  end

  def is_dir?(name)
    name[-1] == "/"
  end

  def url_for(directory, parent_directory="")
    "#{root_url}#{parent_directory}#{directory}"
  end

  def migrate
    work_on_dir("", "")
  end

  def work_on_dir(directory, parent_directory)
    puts "retrieving listing for '#{parent_directory}#{directory}'" if logging

    listing = get_directory_listing_from_swift("#{parent_directory}#{directory}")

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
    puts "adding item #{item} to #{key}" if logging
    redis.sadd(key, item) unless dry_run
  end

  def save_directory_data(dir, item, data, timestamp)
    key = "rs_meta:#{username}:#{dir.gsub(/^\//, "")}#{item}"
    metadata = {etag: data["ETag"], modified: timestamp}

    puts "metadata for dir #{key}: #{metadata}" if logging
    redis.hmset(key, *metadata) unless dry_run
  end

  def save_document_data(dir, item, data, timestamp)
    key = "rs_meta:#{username}:#{dir.gsub(/^\//, "")}#{item}"
    metadata = {
      etag: data["ETag"],
      size: data["Content-Length"],
      type: data["Content-Type"],
      modified: timestamp
    }
    puts "metadata for document #{key}: #{metadata}" if logging
    redis.hmset(key, *metadata) unless dry_run
  end

  def parent_directory_for(directory)
    if directory.match(/\//)
      return directory[0..directory.rindex("/")]
    else
      return "/"
    end
  end

  def redis
    @redis ||= Redis.new(@settings["redis"])
  end

  def get_directory_listing_from_swift(directory)
    is_root_listing = directory.empty?

    get_response = nil

    do_head_request("#{url_for_directory(@username, directory)}") do |response|
      return directory_listing([]) if response.code == 404

      if is_root_listing
        get_response = do_get_request("#{container_url_for(@username)}/?format=json&path=")
      else
        get_response = do_get_request("#{container_url_for(@username)}/?format=json&path=#{escape(directory)}/")
      end
    end

    if body = JSON.parse(get_response.body)
      listing = directory_listing(body)
    else
      puts "listing not JSON"
    end

    listing
  end

  def directory_listing(res_body)
    listing = {
      "@context" => "http://remotestorage.io/spec/folder-description",
      "items"    => {}
    }

    res_body.each do |entry|
      name = entry["name"]
      name.sub!("#{File.dirname(entry["name"])}/", '')
      if name[-1] == "/" # It's a directory
        listing["items"].merge!({
          name => {
            "ETag"           => entry["hash"],
          }
        })
      else # It's a file
        listing["items"].merge!({
          name => {
            "ETag"           => entry["hash"],
            "Content-Type"   => entry["content_type"],
            "Content-Length" => entry["bytes"]
          }
        })
      end
    end

    listing
  end

  def etag_for(body)
    objects = JSON.parse(body)

    if objects.empty?
      Digest::MD5.hexdigest ""
    else
      Digest::MD5.hexdigest objects.map { |o| o["hash"] }.join
    end
  end

  def do_head_request(url, &block)
    RestClient.head(url, default_headers, &block)
  end

  def do_get_request(url, &block)
    RestClient.get(url, default_headers, &block)
  end

  def default_headers
    {"x-auth-token" => @swift_token}
  end

  def url_for_directory(user, directory)
    if directory.empty?
      container_url_for(user)
    else
      "#{container_url_for(user)}/#{escape(directory)}"
    end
  end

  def container_url_for(user)
    "#{base_url}/#{container_for(user)}"
  end

  def base_url
    @base_url ||= @swift_host
  end

  def container_for(user)
    "rs:#{environment.to_s.chars.first}:#{user}"
  end

  def escape(url)
    # We want spaces to turn into %20 and slashes to stay slashes
    CGI::escape(url).gsub('+', '%20').gsub('%2F', '/')
  end
end

username = ARGV[0]

unless username
  puts "No username given."
  puts "Usage:"
  puts "ENVIRONMENT=staging ./migrate_metadata_to_redis.rb <username>"
  exit 1
end

migrator = Migrator.new username
migrator.migrate

