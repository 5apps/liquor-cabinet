require "rest_client"
require "json"
require "cgi"
require "active_support/core_ext/time/conversions"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/hash"
require "redis"
require "digest/md5"

module RemoteStorage
  module RestProvider

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

      server.halt 401, "Unauthorized" if token.nil? || token.empty?

      authorizations = redis.smembers("authorizations:#{user}:#{token}")
      permission = directory_permission(authorizations, directory)

      server.halt 401, "Unauthorized" unless permission
      if ["PUT", "DELETE"].include? request_method
        server.halt 401, "Unauthorized" unless permission == "rw"
      end
    end

    def get_head(user, directory, key)
      none_match = (server.env["HTTP_IF_NONE_MATCH"] || "").split(",")
                                                           .map(&:strip)
                                                           .map { |s| s.gsub(/^"?W\//, "") }
      metadata = redis.hgetall redis_metadata_object_key(user, directory, key)

      server.halt 404 if metadata.empty?

      # Set the response headers for a 304 or 200 response
      server.headers["ETag"]          = %Q("#{metadata["e"]}")
      server.headers["Last-Modified"] = Time.at(metadata["m"].to_i / 1000).httpdate
      server.headers["Content-Type"]  = metadata["t"]
      server.headers["Content-Length"]  = metadata["s"]

      if none_match.include? %Q("#{metadata["e"]}")
        server.halt 304
      end
    end

    def get_data(user, directory, key)
      none_match = (server.env["HTTP_IF_NONE_MATCH"] || "").split(",")
                                                           .map(&:strip)
                                                           .map { |s| s.gsub(/^"?W\//, "") }
      metadata = redis.hgetall redis_metadata_object_key(user, directory, key)
      if none_match.include? %Q("#{metadata["e"]}")
        server.headers["ETag"]           = %Q("#{metadata["e"]}")
        server.headers["Last-Modified"]  = Time.at(metadata["m"].to_i / 1000).httpdate
        server.halt 304
      end

      url = url_for_key(user, directory, key)

      res = do_get_request(url)

      if res.headers[:content_range]
        # Partial content
        server.headers["Content-Range"] = res.headers[:content_range]
        server.status 206
      end
      set_response_headers(metadata)

      return res.body
    rescue RestClient::ResourceNotFound
      server.halt 404, "Not Found"
    end

    def get_head_directory_listing(user, directory)
      get_directory_listing(user, directory)

      "" # just return empty body, headers are set by get_directory_listing
    end

    def get_directory_listing(user, directory)
      etag = redis.hget "rs:m:#{user}:#{directory}/", "e"

      server.headers["Content-Type"] = "application/ld+json"

      none_match = (server.env["HTTP_IF_NONE_MATCH"] || "").split(",")
                                                           .map(&:strip)
                                                           .map { |s| s.gsub(/^"?W\//, "") }

      if etag
        server.halt 304 if none_match.include? %Q("#{etag}")

        items = get_directory_listing_from_redis_via_lua(user, directory)
      else
        etag = etag_for(user, directory)
        items = {}

        server.halt 304 if none_match.include? %Q("#{etag}")
      end

      server.headers["ETag"] = %Q("#{etag}")

      listing = {
        "@context" => "http://remotestorage.io/spec/folder-description",
        "items"    => items
      }

      listing.to_json
    end

    def put_data(user, directory, key, data, content_type)
      # Do not try to perform the PUT request when the Content-Type does not
      # look like a MIME type
      server.halt 415 unless content_type.match(/^.+\/.+/i)
      server.halt 400 if server.env["HTTP_CONTENT_RANGE"]
      server.halt 409, "Conflict" if has_name_collision?(user, directory, key)

      existing_metadata = redis.hgetall redis_metadata_object_key(user, directory, key)
      url = url_for_key(user, directory, key)

      if required_match = server.env["HTTP_IF_MATCH"]
        required_match = required_match.gsub(/^"?W\//, "")
        unless required_match == %Q("#{existing_metadata["e"]}")

          # get actual metadata and compare in case redis metadata became out of sync
          begin
            head_res = do_head_request(url)
          # The file doesn't exist, return 412
          rescue RestClient::ResourceNotFound
            server.halt 412, "Precondition Failed"
          end

          if required_match == format_etag(head_res.headers[:etag])
            # log previous size difference that was missed ealier because of redis failure
            log_size_difference(user, existing_metadata["s"], head_res.headers[:content_length])
          else
            server.halt 412, "Precondition Failed"
          end
        end
      end
      if server.env["HTTP_IF_NONE_MATCH"] == "*"
        server.halt 412, "Precondition Failed" unless existing_metadata.empty?
      end

      etag, timestamp = do_put_request(url, data, content_type)

      metadata = {
        e: etag,
        s: data.size,
        t: content_type,
        m: timestamp
      }

      if update_metadata_object(user, directory, key, metadata)
        if metadata_changed?(existing_metadata, metadata)
          update_dir_objects(user, directory, timestamp, checksum_for(data))
          log_size_difference(user, existing_metadata["s"], metadata[:s])
        end

        server.headers["ETag"] = %Q("#{etag}")
        server.halt existing_metadata.empty? ? 201 : 200
      else
        server.halt 500
      end
    end

    def delete_data(user, directory, key)
      url = url_for_key(user, directory, key)

      existing_metadata = redis.hgetall "rs:m:#{user}:#{directory}/#{key}"

      if required_match = server.env["HTTP_IF_MATCH"]
        unless required_match.gsub(/^"?W\//, "") == %Q("#{existing_metadata["e"]}")
          server.halt 412, "Precondition Failed"
        end
      end

      found = try_to_delete(url)

      log_size_difference(user, existing_metadata["s"], 0)
      delete_metadata_objects(user, directory, key)
      delete_dir_objects(user, directory)

      if found
        server.headers["Etag"] = %Q("#{existing_metadata["e"]}")
        server.halt 200
      else
        server.halt 404, "Not Found"
      end
    end

    private

    # Implement this method in your class that includes this module. For example
    # %Q("#{etag}") if the ETag does not already have quotes around it
    def format_etag(etag)
      NotImplementedError
    end

    def base_url
      NotImplementedError
    end

    def container_url_for(user)
      NotImplementedError
    end

    def default_headers
      raise NotImplementedError
    end

    def set_response_headers(metadata)
      server.headers["ETag"]           = %Q("#{metadata["e"]}")
      server.headers["Last-Modified"]  = Time.at(metadata["m"].to_i / 1000).httpdate
      server.headers["Content-Type"]   = metadata["t"]
      server.headers["Content-Length"] = metadata["s"]
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

    def has_name_collision?(user, directory, key)
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

    def metadata_changed?(old_metadata, new_metadata)
      # check metadata relevant to the directory listing
      return old_metadata["e"] != new_metadata[:e]      ||
             old_metadata["s"] != new_metadata[:s].to_s ||
             old_metadata["m"] != new_metadata[:m]      ||
             old_metadata["t"] != new_metadata[:t]
    end

    def timestamp_for(date)
      return DateTime.parse(date).strftime("%Q").to_i
    end

    def log_size_difference(user, old_size, new_size)
      delta = new_size.to_i - old_size.to_i
      redis.incrby "rs:s:#{user}", delta
    end

    def checksum_for(data)
      Digest::MD5.hexdigest(data)
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
      redis_key = redis_metadata_object_key(user, directory, key)
      redis.hmset(redis_key, *metadata)
      redis.sadd "rs:m:#{user}:#{directory}/:items", key

      true
    end

    def update_dir_objects(user, directory, timestamp, checksum)
      parent_directories_for(directory).each do |dir|
        etag = etag_for(dir, timestamp, checksum)

        key = "rs:m:#{user}:#{dir}/"
        metadata = {e: etag, m: timestamp}
        redis.hmset(key, *metadata)
        redis.sadd "rs:m:#{user}:#{parent_directory_for(dir)}:items", "#{top_directory(dir)}/"
      end
    end

    def delete_metadata_objects(user, directory, key)
      redis.del redis_metadata_object_key(user, directory, key)
      redis.srem "rs:m:#{user}:#{directory}/:items", key
    end

    def delete_dir_objects(user, directory)
      timestamp = (Time.now.to_f * 1000).to_i

      parent_directories_for(directory).each do |dir|
        if dir_empty?(user, dir)
          redis.del "rs:m:#{user}:#{dir}/"
          redis.srem "rs:m:#{user}:#{parent_directory_for(dir)}:items", "#{top_directory(dir)}/"
        else
          etag = etag_for(dir, timestamp)

          metadata = {e: etag, m: timestamp}
          redis.hmset("rs:m:#{user}:#{dir}/", *metadata)
        end
      end
    end

    def dir_empty?(user, dir)
      redis.smembers("rs:m:#{user}:#{dir}/:items").empty?
    end

    def redis_metadata_object_key(user, directory, key)
      "rs:m:#{user}:#{[directory, key].delete_if(&:empty?).join("/")}"
    end

    def url_for_key(user, directory, key)
      File.join [container_url_for(user), escape(directory), escape(key)].compact
    end

    def do_put_request(url, data, content_type)
      deal_with_unauthorized_requests do
        res = RestClient.put(url, data, default_headers.merge({content_type: content_type}))

        return [
          res.headers[:etag],
          timestamp_for(res.headers[:last_modified])
        ]
      end
    end

    def do_get_request(url, &block)
      deal_with_unauthorized_requests do
        headers = { }
        headers["Range"] = server.env["HTTP_RANGE"] if server.env["HTTP_RANGE"]
        RestClient.get(url, default_headers.merge(headers), &block)
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

    def escape(str)
      # We want spaces to turn into %20 and slashes to stay slashes
      CGI::escape(str).gsub('+', '%20').gsub('%2F', '/')
    end

    def redis
      @redis ||= Redis.new(settings.redis.symbolize_keys)
    end

    def etag_for(*args)
      Digest::MD5.hexdigest args.join(":")
    end

    def deal_with_unauthorized_requests(&block)
      begin
        block.call
      rescue RestClient::Unauthorized => ex
        Raven.capture_exception(ex)
        server.halt 500
      end
    end

    def try_to_delete(url)
      found = true

      begin
        do_delete_request(url)
      rescue RestClient::ResourceNotFound
        found = false
      end

      found
    end

    def get_directory_listing_from_redis_via_lua(user, directory)
      lua_script = <<-EOF
        local user = ARGV[1]
        local directory = ARGV[2]
        local items = redis.call("smembers", "rs:m:"..user..":"..directory.."/:items")
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
            listing[name]["Last-Modified"]  = tonumber(metadata["m"])
          end
        end

        return cjson.encode(listing)
      EOF

      items = JSON.parse(redis.eval(lua_script, nil, [user, directory]))

      items.reject{|k, _| k.end_with? "/"}.each do |_, v|
        v["Last-Modified"] = Time.at(v["Last-Modified"]/1000).httpdate
      end

      items
    end

  end
end
