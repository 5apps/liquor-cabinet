#!/usr/bin/env ruby

require "rubygems"
require "bundler/setup"
require "rest_client"
require "redis"
require "yaml"
require "logger"
require "json"
require "active_support/core_ext/hash"

class Migrator

  attr_accessor :username, :base_url, :swift_host, :swift_token,
                :environment, :dry_run, :settings, :logger

  def initialize(username)
    @username = username

    @environment = ENV["ENVIRONMENT"] || "staging"
    @settings = YAML.load(File.read('config.yml'))[@environment]

    @swift_host = @settings["swift"]["host"]
    @swift_token = File.read("tmp/swift_token.txt").strip

    @dry_run = ENV["DRYRUN"] || false # disables writing anything when true

    @logger = Logger.new("log/migrate_to_single_container.log")
    log_level = ENV["LOGLEVEL"] || "INFO"
    logger.level = Kernel.const_get "Logger::#{log_level}"
    logger.progname = username
  end

  def migrate
    logger.info "Starting migration for '#{username}'"
    set_container_migration_state("in_progress")
    begin
      work_on_dir("", "")
    rescue Exception => ex
      logger.error "Error migrating documents for '#{username}': #{ex}"
      set_container_migration_state("not_started")
      # write username to file for later reference
      File.open('log/failed_migration.log', 'a') { |f| f.puts username }
      exit 1
    end
    delete_container_migration_state
    File.open('log/finished_migration.log', 'a') { |f| f.puts username }
    logger.info "Finished migration for '#{username}'"
  end

  def is_dir?(name)
    name[-1] == "/"
  end

  def set_container_migration_state(type)
    redis.set("rs:container_migration:#{username}", type) unless dry_run
  end

  def delete_container_migration_state
    redis.del("rs:container_migration:#{username}") unless dry_run
  end

  def work_on_dir(directory, parent_directory)
    full_directory = "#{parent_directory}#{directory}"
    logger.debug "Retrieving listing for '#{full_directory}'"

    listing = get_directory_listing_from_swift("#{full_directory}")

    logger.debug "Listing for '#{full_directory}': #{listing}"

    if listing
      listing.split("\n").each do |item|
        if is_dir? item
          # get dir listing and repeat
          work_on_dir(item, "#{parent_directory}") unless item == full_directory
        else
          copy_document("#{parent_directory}", item)
        end
      end
    end
  end

  def copy_document(directory, document)
    old_document_url = "#{url_for_directory(@username, directory)}/#{escape(document)}"

    full_path = [directory, document].reject(&:empty?).join('/')
    new_document_path = "rs:documents:#{environment.to_s.downcase}/#{@username}/#{escape(full_path)}"

    logger.debug "Copying document from #{old_document_url} to #{new_document_path}"
    do_copy_request(old_document_url, new_document_path) unless dry_run
  end

  def redis
    @redis ||= Redis.new(@settings["redis"].symbolize_keys)
  end

  def get_directory_listing_from_swift(directory)
    is_root_listing = directory.empty?

    get_response = nil

    if is_root_listing
      get_response = do_get_request("#{container_url_for(@username)}/?delimiter=/&prefix=")
    else
      get_response = do_get_request("#{container_url_for(@username)}/?delimiter=/&prefix=#{escape(directory)}")
    end

    get_response.body
  end

  def do_head_request(url, &block)
    RestClient.head(url, default_headers, &block)
  end

  def do_get_request(url, &block)
    RestClient.get(url, default_headers, &block)
  end

  def do_put_request(url, data, content_type)
    RestClient.put(url, data, default_headers.merge({content_type: content_type}))
  end

  def do_copy_request(url, destination_path)
    RestClient::Request.execute(
      method: :copy,
      url: url,
      headers: default_headers.merge({destination: destination_path})
    )
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
  puts "ENVIRONMENT=staging ./migrate_to_single_container.rb <username>"
  exit 1
end

migrator = Migrator.new username
migrator.migrate

