#!/usr/bin/env ruby

require "rubygems"
require "bundler/setup"
require "rest_client"
require "redis"
require "yaml"
require "logger"
require "active_support/core_ext/hash"

class Migrator

  attr_accessor :username, :base_url, :environment, :settings, :logger

  def initialize(username)
    @username = username

    @environment = ENV["ENVIRONMENT"] || "staging"
    @settings = YAML.load(File.read('config.yml'))[@environment]

    @logger = Logger.new("log/migrate_storage_size_from_metadata.log")
    log_level = ENV["LOGLEVEL"] || "INFO"
    logger.level = Kernel.const_get "Logger::#{log_level}"
    logger.progname = username
  end

  def migrate
    logger.info "Starting migration for '#{username}'"
    set_container_migration_state("in_progress")
    begin
      write_storage_size_from_redis_metadata(username)
    rescue Exception => ex
      logger.error "Error setting storage size from metadata for '#{username}': #{ex}"
      set_container_migration_state("not_started")
      # write username to file for later reference
      File.open('log/failed_migration.log', 'a') { |f| f.puts username }
      exit 1
    end
    delete_container_migration_state
    logger.info "Finished migration for '#{username}'"
  end

  def redis
    @redis ||= Redis.new(@settings["redis"].symbolize_keys)
  end

  def write_storage_size_from_redis_metadata(user)
    lua_script = <<-EOF
      local user = ARGV[1]
      local total_size = 0
      local size_key = KEYS[1]

      local function get_size_from_items(parent, directory)
        local path
        if parent == "/" then
          path = directory
        else
          path = parent..directory
        end
        local items = redis.call("smembers", "rs:m:"..user..":"..path..":items")
        for index, name in pairs(items) do
          local redis_key = "rs:m:"..user..":"

          redis_key = redis_key..path..name

          -- if it's a directory, get the items inside of it
          if string.match(name, "/$") then
            get_size_from_items(path, name)
          -- if it's a file, get its size
          else
            local file_size = redis.call("hget", redis_key, "s")
            total_size = total_size + file_size
          end
        end
      end

      get_size_from_items("", "") -- Start from the root

      redis.call("set", size_key, total_size)
    EOF

    redis.eval(lua_script, ["rs:s:#{user}"], [user])
  end

  def set_container_migration_state(type)
    redis.hset("rs:size_migration", username, type)
  end

  def delete_container_migration_state
    redis.hdel("rs:size_migration", username)
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
    redis.hgetall("rs:size_migration").select { |_, value|
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
