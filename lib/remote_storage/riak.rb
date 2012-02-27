require "riak"

module RemoteStorage
  module Riak

    def authorize_request(user, category, token)
      return true if category == "public" && env["REQUEST_METHOD"] == "GET"

      client = ::Riak::Client.new(settings.riak_config)
      categories = client.bucket("authorizations").get("#{user}:#{token}").data

      halt 403 unless categories.include?(category)
    rescue ::Riak::HTTPFailedRequest
      halt 403
    end

    def get_data(user, category, key)
      client = ::Riak::Client.new(settings.riak_config)
      client.bucket("user_data").get("#{user}:#{category}:#{key}").data
    rescue ::Riak::HTTPFailedRequest
      halt 404
    end

    def put_data(user, category, key, data)
      client = ::Riak::Client.new(settings.riak_config)
      object = client.bucket("user_data").new("#{user}:#{category}:#{key}")
      object.content_type = "text/plain"
      object.data = data
      object.store
    rescue ::Riak::HTTPFailedRequest
      halt 422
    end

    def delete_data(user, category, key)
      client = ::Riak::Client.new(settings.riak_config)
      riak_response = client.bucket("user_data").delete("#{user}:#{category}:#{key}")
      halt riak_response[:code]
    rescue ::Riak::HTTPFailedRequest
      halt 404
    end

  end
end
