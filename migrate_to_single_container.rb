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
      copy_all_documents
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

  def is_document?(name)
    name[-1] != "/"
  end

  def set_container_migration_state(type)
    redis.hset("rs:container_migration", username, type) unless dry_run
  end

  def delete_container_migration_state
    redis.hdel("rs:container_migration", username) unless dry_run
  end

  def copy_all_documents
    logger.debug "Retrieving object listing"

    listing = get_directory_listing_from_swift

    logger.debug "Full listing: #{listing}"

    if listing

      # skip user when there are more files than we can list
      if listing.split("\n").size > 9999
        File.open('log/10k_users.log', 'a') { |f| f.puts username }
        raise "User has too many files"
      end

      listing.split("\n").each do |item|
        if is_document? item
          copy_document(item)
        end
      end

    end
  end

  def copy_document(document_path)
    old_document_url = "#{container_url_for(@username)}/#{escape(document_path)}"

    new_document_path = "rs:documents:#{environment.to_s.downcase}/#{@username}/#{escape(document_path)}"

    logger.debug "Copying document from #{old_document_url} to #{new_document_path}"
    do_copy_request(old_document_url, new_document_path) unless dry_run
  end

  def redis
    @redis ||= Redis.new(@settings["redis"].symbolize_keys)
  end

  def get_directory_listing_from_swift
    get_response = do_get_request("#{container_url_for(@username)}/?prefix=")

    get_response.body
  end

  def do_get_request(url, &block)
    RestClient.get(url, default_headers, &block)
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

class MigrationRunner

  attr_accessor :environment, :settings

  def initialize
    @environment = ENV["ENVIRONMENT"] || "staging"
    @settings = YAML.load(File.read('config.yml'))[@environment]
  end

  def migrate
    while username = pick_unmigrated_user
      migrator = Migrator.new username
      migrator.migrate
    end
  end

  def unmigrated_users
    redis.hgetall("rs:container_migration").select { |_, value|
      value == "not_started"
    }.keys
  end

  def pick_unmigrated_user
    unmigrated_users.sample # pick a random user from list
  end

  def redis
    @redis ||= Redis.new(@settings["redis"].symbolize_keys)
  end

end

username = ARGV[0]

if username
  migrator = Migrator.new username
  migrator.migrate
else
  runner = MigrationRunner.new
  runner.migrate
end

