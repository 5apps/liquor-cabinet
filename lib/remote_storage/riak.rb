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
      @data_bucket ||= client.bucket("user_data")
    end

    def directory_bucket
      @directory_bucket ||= client.bucket("rs_directories")
    end

    def authorize_request(user, directory, token)
      request_method = env["REQUEST_METHOD"]
      return true if directory.split("/").first == "public" && request_method == "GET"

      authorizations = client.bucket("authorizations").get("#{user}:#{token}").data
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
      headers["Last-Modified"] = object.last_modified.to_s(:rfc822)
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
      headers["Content-Type"] = "application/json"
      headers["Last-Modified"] = Time.at(timestamp).to_s(:rfc822)

      listing = directory_listing(user, directory)

      return listing.to_json
    rescue ::Riak::HTTPFailedRequest
      headers["Content-Type"] = "application/json"
      return "{}"
    end

    def put_data(user, directory, key, data, content_type=nil)
      object = data_bucket.new("#{user}:#{directory}:#{key}")
      object.content_type = content_type || "text/plain; charset=utf-8"

      unless set_object_data(object, data)
        halt 422
      end

      directory_index = directory == "" ? "/" : directory
      object.indexes.merge!({:user_id_bin => [user],
                             :directory_bin => [CGI.escape(directory_index)]})
      object.store

      object.reload
      timestamp = object.last_modified.to_i
      update_all_directory_objects(user, directory, timestamp)

      halt 200
    rescue ::Riak::HTTPFailedRequest
      halt 422
    end

    def delete_data(user, directory, key)
      riak_response = data_bucket.delete("#{user}:#{directory}:#{key}")

      timestamp = Time.now.to_i
      delete_or_update_directory_objects(user, directory, timestamp)

      halt riak_response[:code]
    rescue ::Riak::HTTPFailedRequest
      halt 404
    end

    private

    def serializer_for(content_type)
      ::Riak::Serializers[content_type[/^[^;\s]+/]]
    end

    def directory_permission(authorizations, directory)
      authorizations = authorizations.map do |auth|
        auth.index(":") ? auth.split(":") : [auth, "rw"]
      end
      authorizations = Hash[*authorizations.flatten]

      permission = authorizations[""]

      authorizations.each do |key, value|
        if directory.match key
          if permission.nil? || permission == "r"
            permission = value
          end
        end
      end

      permission
    end

    def directory_listing(user, directory)
      listing = {}

      sub_directories(user, directory).each do |entry|
        directory_name = CGI.unescape(entry["name"]).split("/").last
        listing.merge!({ "#{directory_name}/" => entry["timestamp"].to_i })
      end

      directory_entries(user, directory).each do |entry|
        timestamp = DateTime.rfc2822(entry["last_modified"]).to_i
        listing.merge!({ CGI.unescape(entry["name"]) => timestamp })
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
          return [{
            name: key_name,
            last_modified: last_modified_date,
          }];
        }
      EOH

      map_reduce = ::Riak::MapReduce.new(client)
      all_keys.each do |key|
        map_reduce.add("user_data", key)
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
        map_reduce.add("rs_directories", key)
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
      if directory.match /\//
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
