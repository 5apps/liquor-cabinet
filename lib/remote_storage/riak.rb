require "riak"
require "json"
require "cgi"

module RemoteStorage
  module Riak

    def client
      @client ||= ::Riak::Client.new(LiquorCabinet.config['riak'].symbolize_keys)
    end

    def data_bucket
      @data_bucket ||= client.bucket("user_data")
    end

    def directory_bucket
      @directory_bucket ||= client.bucket("rs_directories")
    end

    def authorize_request(user, category, token)
      request_method = env["REQUEST_METHOD"]
      return true if category.split("/").first == "public" && request_method == "GET"

      authorizations = client.bucket("authorizations").get("#{user}:#{token}").data
      permission = category_permission(authorizations, category)

      halt 403 unless permission
      if ["PUT", "DELETE"].include? request_method
        halt 403 unless permission == "rw"
      end
    rescue ::Riak::HTTPFailedRequest
      halt 403
    end

    def get_data(user, category, key)
      object = data_bucket.get("#{user}:#{category}:#{key}")
      headers["Content-Type"] = object.content_type
      headers["Last-Modified"] = object.last_modified.to_s(:rfc822)
      case object.content_type
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
      headers["Content-Type"] = "application/json"
      headers["Last-Modified"] = directory_object.last_modified.to_s(:rfc822)

      listing = directory_listing(user, directory)

      return listing.to_json
    rescue ::Riak::HTTPFailedRequest
      headers["Content-Type"] = "application/json"
      return "{}"
    end

    def put_data(user, category, key, data, content_type=nil)
      object = data_bucket.new("#{user}:#{category}:#{key}")
      object.content_type = content_type || "text/plain; charset=utf-8"
      data = JSON.parse(data) if content_type == "application/json"
      if serializer_for(object.content_type)
        object.data = data
      else
        object.raw_data = data
      end
      object.indexes.merge!({:user_id_bin => [user],
                             :directory_bin => [category]})
      object.store

      update_directory_object(user, category)
    rescue ::Riak::HTTPFailedRequest
      halt 422
    end

    def update_directory_object(user, category)
      if category.match /\//
        parent_directory = category[0..category.rindex("/")-1]
      end
      directory = directory_bucket.new("#{user}:#{category}")
      directory.raw_data = ""
      directory.indexes.merge!({:user_id_bin => [user]})
      if parent_directory
        directory.indexes.merge!({:directory_bin => [parent_directory]})
      end
      directory.store
    end

    def delete_data(user, category, key)
      riak_response = data_bucket.delete("#{user}:#{category}:#{key}")
      if directory_entries(user, category).empty?
        directory_bucket.delete "#{user}:#{category}"
      end
      halt riak_response[:code]
    rescue ::Riak::HTTPFailedRequest
      halt 404
    end

    private

    def serializer_for(content_type)
      ::Riak::Serializers[content_type[/^[^;\s]+/]]
    end

    def category_permission(authorizations, category)
      authorizations = authorizations.map do |auth|
        auth.index(":") ? auth.split(":") : [auth, "rw"]
      end
      authorizations = Hash[*authorizations.flatten]

      permission = authorizations[""]

      authorizations.each do |key, value|
        if category.match key
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
        timestamp = DateTime.rfc2822(entry["last_modified"]).to_time.to_i
        listing.merge!({ "#{entry["name"]}/" => timestamp })
      end

      directory_entries(user, directory).each do |entry|
        timestamp = DateTime.rfc2822(entry["last_modified"]).to_time.to_i
        listing.merge!({ entry["name"] => timestamp })
      end

      listing
    end

    def directory_entries(user, directory)
      map_query = <<-EOH
        function(v){
          keys = v.key.split(':');
          key_name = keys[keys.length-1];
          last_modified_date = v.values[0]['metadata']['X-Riak-Last-Modified'];
          return [{
            name: key_name,
            last_modified: last_modified_date,
          }];
        }
      EOH
      objects = ::Riak::MapReduce.new(client).
        index("user_data", "user_id_bin", user).
        index("user_data", "directory_bin", directory).
        map(map_query, :keep => true).
        run
    end

    def sub_directories(user, directory)
      map_query = <<-EOH
        function(v){
          keys = v.key.split(':');
          key_name = keys[keys.length-1];
          last_modified_date = v.values[0]['metadata']['X-Riak-Last-Modified'];
          return [{
            name: key_name,
            last_modified: last_modified_date,
          }];
        }
      EOH
      objects = ::Riak::MapReduce.new(client).
        index("rs_directories", "user_id_bin", user).
        index("rs_directories", "directory_bin", directory).
        map(map_query, :keep => true).
        run
    end

  end
end
