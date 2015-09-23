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

    def initialize(settings, server, swift_token)
      @settings              = settings
      @server                = server
      @swift_token           = swift_token
      @swift_token_loaded_at = Time.now
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

      if update_dir_objects(user, directory)
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

      parent_directories
    end

    def update_dir_objects(user, directory)
      timestamp = (Time.now.to_f * 1000).to_i

      parent_directories_for(directory).each do |dir|
        do_put_request("#{url_for_directory(user, dir)}/", timestamp.to_s, "text/plain")
      end

      true
    rescue
      parent_directories_for(directory).each do |dir|
        do_delete_request("#{url_for_directory(user, dir)}/") rescue false
      end

      false
    end

    def delete_dir_objects(user, directory)
      parent_directories_for(directory).each do |dir|
        if dir_empty?(user, dir)
          do_delete_request("#{url_for_directory(user, dir)}/")
        else
          timestamp = (Time.now.to_f * 1000).to_i
          do_put_request("#{url_for_directory(user, dir)}/", timestamp.to_s, "text/plain")
        end
      end
    end

    def dir_empty?(user, dir)
      do_get_request("#{container_url_for(user)}/?format=plain&limit=1&path=#{escape(dir)}/") do |res|
        return res.headers[:content_length] == "0"
      end
    end

    def container_url_for(user)
      "#{base_url}/#{container_for(user)}"
    end

    def url_for_key(user, directory, key)
      "#{container_url_for(user)}/#{escape(directory)}/#{escape(key)}"
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
      RestClient.put(url, data, default_headers.merge({content_type: content_type}))
    end

    def do_get_request(url, &block)
      RestClient.get(url, default_headers, &block)
    end

    def do_head_request(url, &block)
      RestClient.head(url, default_headers, &block)
    end

    def do_delete_request(url)
      RestClient.delete(url, default_headers)
    end

    def escape(url)
      # We want spaces to turn into %20 and slashes to stay slashes
      CGI::escape(url).gsub('+', '%20').gsub('%2F', '/')
    end

    def redis
      @redis ||= Redis.new(host: settings.redis["host"], port: settings.redis["port"])
    end

    def etag_for(body)
      objects = JSON.parse(body)

      if objects.empty?
        Digest::MD5.hexdigest ''
      else
        Digest::MD5.hexdigest objects.map { |o| o["hash"] }.join
      end
    end

    def load_swift_token
      @swift_token           = File.read(swift_token_path)
      @swift_token_loaded_at = Time.now
    end
    def swift_token_path
      "tmp/swift_token.txt"
    end

    def swift_token
      load_swift_token if Time.now - @swift_token_loaded_at > 3600

      @swift_token
    end
  end
end
