require "riak"
require "json"
require "cgi"

module RemoteStorage
  module Riak

    ::Riak.url_decoding = true

    def client
      @client ||= ::Riak::Client.new(LiquorCabinet.config['riak'].symbolize_keys)
    end

    def data_bucket
      @data_bucket ||= client.bucket(LiquorCabinet.config['buckets']['data'])
    end

    def directory_bucket
      @directory_bucket ||= client.bucket(LiquorCabinet.config['buckets']['directories'])
    end

    def auth_bucket
      @auth_bucket ||= client.bucket(LiquorCabinet.config['buckets']['authorizations'])
    end

    def binary_bucket
      @binary_bucket ||= client.bucket(LiquorCabinet.config['buckets']['binaries'])
    end

    def info_bucket
      @info_bucket ||= client.bucket(LiquorCabinet.config['buckets']['info'])
    end

    def authorize_request(user, directory, token, listing=false)
      request_method = env["REQUEST_METHOD"]

      if directory.split("/").first == "public"
        return true if request_method == "GET" && !listing
      end

      authorizations = auth_bucket.get("#{user}:#{token}").data
      permission = directory_permission(authorizations, directory)

      halt 403 unless permission
      if ["PUT", "DELETE"].include? request_method
        halt 403 unless permission == "rw"
      end
    rescue ::Riak::HTTPFailedRequest
      halt 403
    end

    def get_data(user, directory, key)
      object = data_bucket.get("#{user}:#{directory}:#{key}")

      headers["Content-Type"] = object.content_type
      headers["Last-Modified"] = last_modified_date_for(object)

      if binary_link = object.links.select {|l| l.tag == "binary"}.first
        object = client[binary_link.bucket].get(binary_link.key)
      end

      case object.content_type[/^[^;\s]+/]
      when "application/json"
        return object.data.to_json
      else
        return serializer_for(object.content_type) ? object.data : object.raw_data
      end
    rescue ::Riak::HTTPFailedRequest
      halt 404
    end

    def get_directory_listing(user, directory)
      directory_object = directory_bucket.get("#{user}:#{directory}")
      timestamp = directory_object.data.to_i
      timestamp /= 1000 if timestamp.to_s.length == 13
      headers["Content-Type"] = "application/json"
      headers["Last-Modified"] = Time.at(timestamp).to_s(:rfc822)

      listing = directory_listing(user, directory)

      return listing.to_json
    rescue ::Riak::HTTPFailedRequest
      headers["Content-Type"] = "application/json"
      return "{}"
    end

    def put_data(user, directory, key, data, content_type=nil)
      object = build_data_object(user, directory, key, data, content_type)

      object_exists = !object.data.nil?
      existing_object_size = object_size(object)

      timestamp = (Time.now.to_f * 1000).to_i
      object.meta["timestamp"] = timestamp

      if binary_data?(object.content_type, data)
        save_binary_data(object, data) or halt 422
        new_object_size = data.size
      else
        set_object_data(object, data) or halt 422
        new_object_size = object.raw_data.size
      end

      object.store

      log_object_count(user, directory, 1) unless object_exists
      log_object_size(user, directory, new_object_size, existing_object_size)
      update_all_directory_objects(user, directory, timestamp)

      halt 200
    rescue ::Riak::HTTPFailedRequest
      halt 422
    end

    def delete_data(user, directory, key)
      object = data_bucket.get("#{user}:#{directory}:#{key}")
      existing_object_size = object_size(object)

      if binary_link = object.links.select {|l| l.tag == "binary"}.first
        client[binary_link.bucket].delete(binary_link.key)
      end

      riak_response = data_bucket.delete("#{user}:#{directory}:#{key}")

      log_object_count(user, directory, -1)
      log_object_size(user, directory, 0, existing_object_size)

      timestamp = (Time.now.to_f * 1000).to_i
      delete_or_update_directory_objects(user, directory, timestamp)

      halt riak_response[:code]
    rescue ::Riak::HTTPFailedRequest
      halt 404
    end


    private

    def extract_category(directory)
      if directory.match(/^public\//)
        "public/#{directory.split('/')[1]}"
      else
        directory.split('/').first
      end
    end

    def build_data_object(user, directory, key, data, content_type=nil)
      object = data_bucket.get_or_new("#{user}:#{directory}:#{key}")

      object.content_type = content_type || "text/plain; charset=utf-8"

      directory_index = directory == "" ? "/" : directory
      object.indexes.merge!({:user_id_bin => [user],
                             :directory_bin => [CGI.escape(directory_index)]})

      object
    end

    def log_object_size(user, directory, new_size=0, old_size=0)
      category = extract_category(directory)
      info = info_bucket.get_or_new("usage:#{user}:#{category}")
      info.content_type = "application/json"
      info.data ||= {}
      info.data["size"] ||= 0
      info.data["size"] += (-old_size + new_size)
      info.indexes.merge!({:user_id_bin => [user]})
      info.store
    end

    def log_object_count(user, directory, change)
      category = extract_category(directory)
      info = info_bucket.get_or_new("usage:#{user}:#{category}")
      info.content_type = "application/json"
      info.data ||= {}
      info.data["count"] ||= 0
      info.data["count"] += change
      info.indexes.merge!({:user_id_bin => [user]})
      info.store
    end

    def object_size(object)
      if binary_link = object.links.select {|l| l.tag == "binary"}.first
        response = head(LiquorCabinet.config['buckets']['binaries'], escape(binary_link.key))
        response[:headers]["content-length"].first.to_i
      else
        object.raw_data.nil? ? 0 : object.raw_data.size
      end
    end

    def escape(string)
      ::Riak.escaper.escape(string).gsub("+", "%20").gsub('/', "%2F")
    end

    # Perform a HEAD request via the backend method
    def head(bucket, key)
      client.http do |h|
        url = riak_uri(bucket, key)
        h.head [200], url
      end
    end

    # A URI object that can be used with HTTP backend methods
    def riak_uri(bucket, key)
      rc = LiquorCabinet.config['riak'].symbolize_keys
      URI.parse "http://#{rc[:host]}:#{rc[:http_port]}/riak/#{bucket}/#{key}"
    end

    def serializer_for(content_type)
      ::Riak::Serializers[content_type[/^[^;\s]+/]]
    end

    def last_modified_date_for(object)
      timestamp = object.meta["timestamp"]
      timestamp = (timestamp[0].to_i / 1000) if timestamp
      last_modified = timestamp ? Time.at(timestamp) : object.last_modified

      last_modified.to_s(:rfc822)
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

    def directory_listing(user, directory)
      listing = {}

      sub_directories(user, directory).each do |entry|
        directory_name = CGI.unescape(entry["name"]).split("/").last
        timestamp = entry["timestamp"].to_i

        listing.merge!({ "#{directory_name}/" => timestamp })
      end

      directory_entries(user, directory).each do |entry|
        entry_name = CGI.unescape(entry["name"])
        timestamp = if entry["timestamp"]
                      entry["timestamp"].to_i
                    else
                      DateTime.rfc2822(entry["last_modified"]).to_i
                    end

        listing.merge!({ CGI.escape(entry_name) => timestamp })
      end

      listing
    end

    def directory_entries(user, directory)
      directory = "/" if directory == ""

      user_keys = data_bucket.get_index("user_id_bin", user)
      directory_keys = data_bucket.get_index("directory_bin", directory)

      all_keys = user_keys & directory_keys
      return [] if all_keys.empty?

      map_query = <<-EOH
        function(v){
          keys = v.key.split(':');
          keys.splice(0, 2);
          key_name = keys.join(':');
          last_modified_date = v.values[0]['metadata']['X-Riak-Last-Modified'];
          timestamp = v.values[0]['metadata']['X-Riak-Meta']['X-Riak-Meta-Timestamp'];
          return [{
            name: key_name,
            last_modified: last_modified_date,
            timestamp: timestamp,
          }];
        }
      EOH

      map_reduce = ::Riak::MapReduce.new(client)
      all_keys.each do |key|
        map_reduce.add(data_bucket.name, key)
      end

      map_reduce.
        map(map_query, :keep => true).
        run
    end

    def sub_directories(user, directory)
      directory = "/" if directory == ""

      user_keys = directory_bucket.get_index("user_id_bin", user)
      directory_keys = directory_bucket.get_index("directory_bin", directory)

      all_keys = user_keys & directory_keys
      return [] if all_keys.empty?

      map_query = <<-EOH
        function(v){
          keys = v.key.split(':');
          key_name = keys[keys.length-1];
          timestamp = v.values[0]['data']
          return [{
            name: key_name,
            timestamp: timestamp,
          }];
        }
      EOH

      map_reduce = ::Riak::MapReduce.new(client)
      all_keys.each do |key|
        map_reduce.add(directory_bucket.name, key)
      end

      map_reduce.
        map(map_query, :keep => true).
        run
    end

    def update_all_directory_objects(user, directory, timestamp)
      parent_directories_for(directory).each do |parent_directory|
        update_directory_object(user, parent_directory, timestamp)
      end
    end

    def update_directory_object(user, directory, timestamp)
      if directory.match(/\//)
        parent_directory = directory[0..directory.rindex("/")-1]
      elsif directory != ""
        parent_directory = "/"
      end

      directory_object = directory_bucket.new("#{user}:#{directory}")
      directory_object.content_type = "text/plain; charset=utf-8"
      directory_object.data = timestamp.to_s
      directory_object.indexes.merge!({:user_id_bin => [user]})
      if parent_directory
        directory_object.indexes.merge!({:directory_bin => [CGI.escape(parent_directory)]})
      end
      directory_object.store
    end

    def delete_or_update_directory_objects(user, directory, timestamp)
      parent_directories_for(directory).each do |parent_directory|
        existing_files = directory_entries(user, parent_directory)
        existing_subdirectories = sub_directories(user, parent_directory)

        if existing_files.empty? && existing_subdirectories.empty?
          directory_bucket.delete "#{user}:#{parent_directory}"
        else
          update_directory_object(user, parent_directory, timestamp)
        end
      end
    end

    def set_object_data(object, data)
      if object.content_type[/^[^;\s]+/] == "application/json"
        data = "{}" if data.blank?
        data = JSON.parse(data)
      end

      if serializer_for(object.content_type)
        object.data = data
      else
        object.raw_data = data
      end
    rescue JSON::ParserError
      return false
    end

    def save_binary_data(object, data)
      binary_object = binary_bucket.new(object.key)
      binary_object.content_type = object.content_type
      binary_object.raw_data = data
      binary_object.indexes = object.indexes
      binary_object.store

      link = ::Riak::Link.new(binary_bucket.name, binary_object.key, "binary")
      object.links << link
      object.raw_data = ""
    end

    def binary_data?(content_type, data)
      return true if content_type[/[^;\s]+$/] == "charset=binary"

      original_encoding = data.encoding
      data.force_encoding("UTF-8")
      is_binary = !data.valid_encoding?
      data.force_encoding(original_encoding)

      is_binary
    end

    def parent_directories_for(directory)
      directories = directory.split("/")
      parent_directories = []

      while directories.any?
        parent_directories << directories.join("/")
        directories.pop
      end

      parent_directories << ""
    end
  end
end
