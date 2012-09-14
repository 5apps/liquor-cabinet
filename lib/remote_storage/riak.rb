require "riak"
require "json"

module RemoteStorage
  module Riak

    def client
      @client ||= ::Riak::Client.new(LiquorCabinet.config['riak'].symbolize_keys)
    end

    def authorize_request(user, category, token)
      return true if category == "public" && env["REQUEST_METHOD"] == "GET"

      categories = client.bucket("authorizations").get("#{user}:#{token}").data

      halt 403 unless categories.include?(category)
    rescue ::Riak::HTTPFailedRequest
      halt 403
    end

    def get_data(user, category, key)
      object = client.bucket("user_data").get("#{user}:#{category}:#{key}")
      headers["Content-Type"] = object.content_type
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
      object = client.bucket("user_data").new("#{user}:#{category}:#{key}")
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
      riak_response = client.bucket("user_data").delete("#{user}:#{category}:#{key}")
      halt riak_response[:code]
    rescue ::Riak::HTTPFailedRequest
      halt 404
    end

    private

    def serializer_for(content_type)
      ::Riak::Serializers[content_type[/^[^;\s]+/]]
    end

  end
end
