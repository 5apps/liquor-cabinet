#!/usr/bin/env ruby

require "rubygems"
require "bundler/setup"
require "rest_client"
require "redis"
require "yaml"
require "logger"
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

    @dry_run = ENV["DRYRUN"] || false # disables writing anything to Redis when true

    @logger = Logger.new("log/migrate_root_metadata_to_redis.log")
    log_level = ENV["LOGLEVEL"] || "INFO"
    logger.level = Kernel.const_get "Logger::#{log_level}"
    logger.progname = username
  end

  def root_url
    "#{@base_url}/#{@username}"
  end

  def migrate
    logger.info "Starting migration for '#{username}'"
    begin
      work_on_dir("")
    rescue Exception => ex
      logger.error "Error migrating metadata for '#{username}': #{ex}"
      # write username to file for later reference
      File.open('log/failed_root_migration.log', 'a') { |f| f.puts username }
      exit 1
    end
    logger.info "Finished migration for '#{username}'"
  end

  def work_on_dir(directory)
    logger.debug "Retrieving root metadata for '#{username}'"

    response = do_head_request("#{container_url_for(@username)}")

    save_root_directory_data(response)
  end

  def save_root_directory_data(response)
    key = "rs:m:#{username}:/"

    metadata = {
      e: etag_for(response.headers[:x_timestamp], response.headers[:x_trans_id]),
      m: (response.headers[:x_timestamp].to_f * 1000).to_i
    }

    logger.debug "Metadata for dir #{key}: #{metadata}"
    redis.hmset(key, *metadata) unless dry_run
  end

  def etag_for(*args)
    Digest::MD5.hexdigest args.join(":")
  end

  def redis
    @redis ||= Redis.new(@settings["redis"].symbolize_keys)
  end

  def do_head_request(url, &block)
    RestClient.head(url, default_headers, &block)
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
end

username = ARGV[0]

unless username
  puts "No username given."
  puts "Usage:"
  puts "ENVIRONMENT=staging ./migrate_root_metadata_to_redis.rb <username>"
  exit 1
end

migrator = Migrator.new username
migrator.migrate

