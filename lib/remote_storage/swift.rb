require "rest_client"
require "json"
require "cgi"
require "active_support/core_ext/time/conversions"
require "active_support/core_ext/numeric/time"
require "redis"
require "digest/md5"

module RemoteStorage
  class Swift

    attr_accessor :settings, :server

    def initialize(settings, server)
      @settings = settings
      @server   = server
    end

    def authorize_request(user, directory, token, listing=false)
      request_method = server.env["REQUEST_METHOD"]

      if directory.split("/").first == "public"
        return true if ["GET", "HEAD"].include?(request_method) && !listing
      end

      authorizations = redis.smembers("authorizations:#{user}:#{token}")
      permission = directory_permission(authorizations, directory)

      server.halt 401 unless permission
      if ["PUT", "DELETE"].include? request_method
        server.halt 503 if directory_backend(user).match(/locked/)
        server.halt 401 unless permission == "rw"
      end
    end

    def get_head(user, directory, key)
      url = url_for_key(user, directory, key)

      res = do_head_request(url)

      set_response_headers(res)
    rescue RestClient::ResourceNotFound
      server.halt 404
    end

    def get_data(user, directory, key)
      url = url_for_key(user, directory, key)

      res = do_get_request(url)

      set_response_headers(res)

      none_match = (server.env["HTTP_IF_NONE_MATCH"] || "").split(",").map(&:strip)
      server.halt 304 if none_match.include? %Q("#{res.headers[:etag]}")

      return res.body
    rescue RestClient::ResourceNotFound
      server.halt 404
    end

    def get_head_directory_listing(user, directory)
      is_root_listing = directory.empty?
      if is_root_listing
        # We need to calculate the etag ourselves
        res = do_get_request("#{url_for_directory(user, directory)}/?format=json")
        etag = etag_for(res.body)
      else
        res  = do_head_request("#{url_for_directory(user, directory)}/")
        etag = res.headers[:etag]
      end

      server.headers["Content-Type"] = "application/json"
      server.headers["ETag"]         = %Q("#{etag}")
    rescue RestClient::ResourceNotFound
      server.halt 404
    end

    def get_directory_listing(user, directory)
      if directory_backend(user).match(/new/)
        get_directory_listing_from_redis(user, directory)
      else
        get_directory_listing_from_swift(user, directory)
      end
    end

    def get_directory_listing_from_redis_via_lua(user, directory)
      lua_script = <<-EOF
        local user = ARGV[1]
        local directory = ARGV[2]
        local items = redis.call("smembers", "rs:m:"..user..":"..directory.."/:i")
        local listing = {}

        for index, name in pairs(items) do
          local redis_key = "rs:m:"..user..":"
          if directory == "" then
            redis_key = redis_key..name
          else
            redis_key = redis_key..directory.."/"..name
          end

          local metadata_values = redis.call("hgetall", redis_key)
          local metadata = {}

          -- redis returns hashes as a single list of alternating keys and values
          -- this collates it into a table
          for idx = 1, #metadata_values, 2 do
            metadata[metadata_values[idx]] = metadata_values[idx + 1]
          end

          listing[name] = {["ETag"] = metadata["e"]}
          if string.sub(name, -1) ~= "/" then
            listing[name]["Content-Type"]   = metadata["t"]
            listing[name]["Content-Length"] = tonumber(metadata["s"])
          end
        end

        return cjson.encode(listing)
      EOF

      JSON.parse(redis.eval(lua_script, nil, [user, directory]))
    end

    def get_directory_listing_from_redis(user, directory)
      etag = redis.hget "rs:m:#{user}:#{directory}/", "e"

      none_match = (server.env["HTTP_IF_NONE_MATCH"] || "").split(",").map(&:strip)
      server.halt 304 if none_match.include? etag

      server.headers["Content-Type"] = "application/json"
      server.headers["ETag"] = %Q("#{etag}")

      listing = {
        "@context" => "http://remotestorage.io/spec/folder-description",
        "items"    => get_directory_listing_from_redis_via_lua(user, directory)
      }

      listing.to_json
    end

    def get_directory_listing_from_swift(user, directory)
      is_root_listing = directory.empty?

      server.headers["Content-Type"] = "application/json"

      etag, get_response = nil

      do_head_request("#{url_for_directory(user, directory)}/") do |response|
        return directory_listing([]).to_json if response.code == 404

        if is_root_listing
          get_response = do_get_request("#{container_url_for(user)}/?format=json&path=")
          etag = etag_for(get_response.body)
        else
          get_response = do_get_request("#{container_url_for(user)}/?format=json&path=#{escape(directory)}/")
          etag = response.headers[:etag]
        end

        none_match = (server.env["HTTP_IF_NONE_MATCH"] || "").split(",").map(&:strip)
        server.halt 304 if none_match.include? %Q("#{etag}")
      end

      server.headers["ETag"] = %Q("#{etag}")

      if body = JSON.parse(get_response.body)
        listing = directory_listing(body)
      else
        puts "listing not JSON"
      end

      listing.to_json
    end

    def put_data(user, directory, key, data, content_type)
      server.halt 409 if has_name_collision?(user, directory, key)

      url = url_for_key(user, directory, key)

      if required_match = server.env["HTTP_IF_MATCH"]
        do_head_request(url) do |response|
          server.halt 412 unless required_match == %Q("#{response.headers[:etag]}")
        end
      end
      if server.env["HTTP_IF_NONE_MATCH"] == "*"
        do_head_request(url) do |response|
          server.halt 412 unless response.code == 404
        end
      end

      res = do_put_request(url, data, content_type)

      # TODO use actual last modified time from the document put request
      timestamp = (Time.now.to_f * 1000).to_i

      metadata = {
        e: res.headers[:etag],
        s: data.size,
        t: content_type,
        m: timestamp
      }

      if update_metadata_object(user, directory, key, metadata) &&
         update_dir_objects(user, directory, timestamp)
        server.headers["ETag"] = %Q("#{res.headers[:etag]}")
        server.halt 200
      else
        server.halt 500
      end
    end

    def delete_data(user, directory, key)
      url = url_for_key(user, directory, key)

      if required_match = server.env["HTTP_IF_MATCH"]
        do_head_request(url) do |response|
          server.halt 412 unless required_match == %Q("#{response.headers[:etag]}")
        end
      end

      do_delete_request(url)
      delete_metadata_objects(user, directory, key)
      delete_dir_objects(user, directory)

      server.halt 200
    rescue RestClient::ResourceNotFound
      server.halt 404
    end

    private

    def set_response_headers(response)
      server.headers["ETag"]           = %Q("#{response.headers[:etag]}")
      server.headers["Content-Type"]   = response.headers[:content_type]
      server.headers["Content-Length"] = response.headers[:content_length]
      server.headers["Last-Modified"]  = response.headers[:last_modified]
    end

    def extract_category(directory)
      if directory.match(/^public\//)
        "public/#{directory.split('/')[1]}"
      else
        directory.split('/').first
      end
    end

    def directory_permission(authorizations, directory)
      authorizations = authorizations.map do |auth|
        auth.index(":") ? auth.split(":") : [auth, "rw"]
      end
      authorizations = Hash[*authorizations.flatten]

      permission = authorizations[""]

      authorizations.each do |key, value|
        if directory.match(/^(public\/)?#{key}(\/|$)/)
          if permission.nil? || permission == "r"
            permission = value
          end
          return permission if permission == "rw"
        end
      end

      permission
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

    def has_name_collision?(user, directory, key)
      if directory_backend(user).match(/new/)
        has_name_collision_via_redis?(user, directory, key)
      else
        has_name_collision_via_swift?(user, directory, key)
      end
    end

    def has_name_collision_via_redis?(user, directory, key)
      lua_script = <<-EOF
        local user = ARGV[1]
        local directory = ARGV[2]
        local key = ARGV[3]

        -- build table with parent directories from remaining arguments
        local parent_dir_count = #ARGV - 3
        local parent_directories = {}
        for i = 4, 4 + parent_dir_count do
          table.insert(parent_directories, ARGV[i])
        end

        -- check for existing directory with the same name as the document
        local redis_key = "rs:m:"..user..":"
        if directory == "" then
          redis_key = redis_key..key.."/"
        else
          redis_key = redis_key..directory.."/"..key.."/"
        end
        if redis.call("hget", redis_key, "e") then
          return true
        end

        for index, dir in pairs(parent_directories) do
          if redis.call("hget", "rs:m:"..user..":"..dir.."/", "e") then
            -- the directory already exists, no need to do further checks
            return false
          else
            -- check for existing document with same name as directory
            if redis.call("hget", "rs:m:"..user..":"..dir, "e") then
              return true
            end
          end
        end

        return false
      EOF

      parent_directories = parent_directories_for(directory)

      redis.eval(lua_script, nil, [user, directory, key, *parent_directories])
    end

    def has_name_collision_via_swift?(user, directory, key)
      # check for existing directory with the same name as the document
      url = url_for_key(user, directory, key)
      do_head_request("#{url}/") do |res|
        return true if res.code == 200
      end

      # check for existing documents with the same name as one of the parent directories
      parent_directories_for(directory).each do |dir|
        do_head_request("#{url_for_directory(user, dir)}/") do |res_dir|
          if res_dir.code == 200
            return false
          else
            do_head_request("#{url_for_directory(user, dir)}") do |res_key|
              if res_key.code == 200
                return true
              else
                next
              end
            end
          end
        end
      end

      false
    end

    def parent_directories_for(directory)
      directories = directory.split("/")
      parent_directories = []

      while directories.any?
        parent_directories << directories.join("/")
        directories.pop
      end

      parent_directories << "" # add empty string for the root directory

      parent_directories
    end

    def top_directory(directory)
      if directory.match(/\//)
        directory.split("/").last
      elsif directory != ""
        return directory
      end
    end

    def parent_directory_for(directory)
      if directory.match(/\//)
        return directory[0..directory.rindex("/")]
      elsif directory != ""
        return "/"
      end
    end

    def update_metadata_object(user, directory, key, metadata)
      redis_key = "rs:m:#{user}:#{directory}/#{key}"
      redis.hmset(redis_key, *metadata)
      redis.sadd "rs:m:#{user}:#{directory}/:i", key

      true
    end

    def update_dir_objects(user, directory, timestamp)
      parent_directories_for(directory).each do |dir|
        unless dir == ""
          res = do_put_request("#{url_for_directory(user, dir)}/", timestamp.to_s, "text/plain")
          etag = res.headers[:etag]
        else
          get_response = do_get_request("#{container_url_for(user)}/?format=json&path=")
          etag = etag_for(get_response.body)
        end

        key = "rs:m:#{user}:#{dir}/"
        metadata = {e: etag, m: timestamp}
        redis.hmset(key, *metadata)
        redis.sadd "rs:m:#{user}:#{parent_directory_for(dir)}:i", "#{top_directory(dir)}/"
      end

      true
    rescue
      parent_directories_for(directory).each do |dir|
        unless dir == ""
          do_delete_request("#{url_for_directory(user, dir)}/") rescue false
        end
      end

      false
    end

    def delete_metadata_objects(user, directory, key)
      redis_key = "rs:m:#{user}:#{directory}/#{key}"
      redis.del(redis_key)
      redis.srem "rs:m:#{user}:#{directory}/:i", key
    end

    def delete_dir_objects(user, directory)
      timestamp = (Time.now.to_f * 1000).to_i

      parent_directories_for(directory).each do |dir|
        if dir_empty?(user, dir)
          unless dir == ""
            do_delete_request("#{url_for_directory(user, dir)}/")
          end
          redis.del "rs:m:#{user}:#{directory}/"
          redis.srem "rs:m:#{user}:#{parent_directory_for(dir)}:i", "#{dir}/"
        else
          unless dir == ""
            res = do_put_request("#{url_for_directory(user, dir)}/", timestamp.to_s, "text/plain")
            etag = res.headers[:etag]
          else
            get_response = do_get_request("#{container_url_for(user)}/?format=json&path=")
            etag = etag_for(get_response.body)
          end
          metadata = {e: etag, m: timestamp}
          redis.hmset("rs:m:#{user}:#{dir}/", *metadata)
        end
      end
    end

    def dir_empty?(user, dir)
      if directory_backend(user).match(/new/)
        redis.smembers("rs:m:#{user}:#{dir}/:i").empty?
      else
        do_get_request("#{container_url_for(user)}/?format=plain&limit=1&path=#{escape(dir)}/") do |res|
          return res.headers[:content_length] == "0"
        end
      end
    end

    def container_url_for(user)
      "#{base_url}/#{container_for(user)}"
    end

    def url_for_key(user, directory, key)
      File.join [container_url_for(user), escape(directory), escape(key)].compact
    end

    def url_for_directory(user, directory)
      if directory.empty?
        container_url_for(user)
      else
        "#{container_url_for(user)}/#{escape(directory)}"
      end
    end

    def base_url
      @base_url ||= settings.swift["host"]
    end

    def container_for(user)
      "rs:#{settings.environment.to_s.chars.first}:#{user}"
    end

    def default_headers
      {"x-auth-token" => swift_token}
    end

    def do_put_request(url, data, content_type)
      deal_with_unauthorized_requests do
        RestClient.put(url, data, default_headers.merge({content_type: content_type}))
      end
    end

    def do_get_request(url, &block)
      deal_with_unauthorized_requests do
        RestClient.get(url, default_headers, &block)
      end
    end

    def do_head_request(url, &block)
      deal_with_unauthorized_requests do
        RestClient.head(url, default_headers, &block)
      end
    end

    def do_delete_request(url)
      deal_with_unauthorized_requests do
        RestClient.delete(url, default_headers)
      end
    end

    def escape(url)
      # We want spaces to turn into %20 and slashes to stay slashes
      CGI::escape(url).gsub('+', '%20').gsub('%2F', '/')
    end

    def redis
      @redis ||= Redis.new(settings.redis)
    end

    def directory_backend(user)
      @directory_backend ||= redis.get("rsc:db:#{user}") || "legacy"
    end

    def etag_for(body)
      objects = JSON.parse(body)

      if objects.empty?
        Digest::MD5.hexdigest ''
      else
        Digest::MD5.hexdigest objects.map { |o| o["hash"] }.join
      end
    end

    def reload_swift_token
      server.logger.debug "Reloading swift token. Old token: #{settings.swift_token}"
      settings.swift_token           = File.read(swift_token_path)
      settings.swift_token_loaded_at = Time.now
      server.logger.debug "Reloaded swift token. New token: #{settings.swift_token}"
    end

    def swift_token_path
      "tmp/swift_token.txt"
    end

    def swift_token
      reload_swift_token if Time.now - settings.swift_token_loaded_at > 3600

      settings.swift_token
    end

    def deal_with_unauthorized_requests(&block)
      begin
        block.call
      rescue RestClient::Unauthorized => ex
        Raven.capture_exception(
          ex,
          tags: { swift_token:           settings.swift_token,
                  swift_token_loaded_at: settings.swift_token_loaded_at }
        )
        server.halt 500
      end
    end
  end
end
