
module RemoteStorage
  module Riak

    include RemoteStorage::BackendInterface

    def self.included(base)
      require "riak"
    end

    def authorize_request(user, category, token)
      return true if category == "public" && env["REQUEST_METHOD"] == "GET"

      categories = client.bucket("authorizations").get("#{user}:#{token}").data

      halt 403 unless categories.include?(category)
    rescue ::Riak::HTTPFailedRequest
      halt 403
    end

    def get_data(user, category, key)
      client.bucket("user_data").get("#{user}:#{category}:#{key}").data
    rescue ::Riak::HTTPFailedRequest
      halt 404
    end

    def put_data(user, category, key, data)
      object = client.bucket("user_data").new("#{user}:#{category}:#{key}")
      object.content_type = "text/plain"
      object.data = data
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

    protected

    def client
      return @client if @client
      @client = ::Riak::Client.new(LiquorCabinet.config['riak'].symbolize_keys)
    end

  end
end
