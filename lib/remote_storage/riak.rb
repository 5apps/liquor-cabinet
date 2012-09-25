require "riak"
require "json"

module RemoteStorage
  module Riak

    def client
      @client ||= ::Riak::Client.new(LiquorCabinet.config['riak'].symbolize_keys)
    end

    def data_bucket
      @data_bucket ||= client.bucket("user_data")
    end

    def authorize_request(user, category, token)
      request_method = env["REQUEST_METHOD"]
      return true if category == "public" && request_method == "GET"

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

    def put_data(user, category, key, data, content_type=nil)
      object = data_bucket.new("#{user}:#{category}:#{key}")
      object.content_type = content_type || "text/plain; charset=utf-8"
      data = JSON.parse(data) if content_type == "application/json"
      if serializer_for(object.content_type)
        object.data = data
      else
        object.raw_data = data
      end
      object.indexes.merge!({:user_id_bin => [user]})
      object.store
    rescue ::Riak::HTTPFailedRequest
      halt 422
    end

    def delete_data(user, category, key)
      riak_response = data_bucket.delete("#{user}:#{category}:#{key}")
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

  end
end
