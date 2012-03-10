require_relative "spec_helper"

if LiquorCabinet.config['backend'] == 'riak'

  extend(Configuration)

  set :riak_config, config['riak'].symbolize_keys

  describe "App with Riak backend" do
    include Rack::Test::Methods
    include RemoteStorage::Riak

    def app
      LiquorCabinet
    end

    def storage_client
      ::Riak::Client.new(settings.riak_config)
    end

    describe "GET public data" do
      before do
        object = storage_client.bucket("user_data").new("jimmy:public:foo")
        object.content_type = "text/plain"
        object.data = "some text data"
        object.store
      end

      after do
        storage_client.bucket("user_data").delete("jimmy:public:foo")
      end

      it "returns the value on all get requests" do
        get "/jimmy/public/foo"

        last_response.status.must_equal 200
        last_response.body.must_equal "some text data"
      end
    end

    describe "private data" do
      before do
        object = storage_client.bucket("user_data").new("jimmy:documents:foo")
        object.content_type = "text/plain"
        object.data = "some private text data"
        object.store

        auth = storage_client.bucket("authorizations").new("jimmy:123")
        auth.data = ["documents", "public"]
        auth.store
      end

      after do
        storage_client.bucket("user_data").delete("jimmy:documents:foo")
        storage_client.bucket("authorizations").delete("jimmy:123")
      end

      describe "GET" do
        it "returns the value" do
          header "Authorization", "Bearer 123"
          get "/jimmy/documents/foo"

          last_response.status.must_equal 200
          last_response.body.must_equal "some private text data"
        end
      end

      describe "GET nonexisting key" do
        it "returns a 404" do
          header "Authorization", "Bearer 123"
          get "/jimmy/documents/somestupidkey"

          last_response.status.must_equal 404
        end
      end

      describe "PUT" do
        it "saves the value" do
          header "Authorization", "Bearer 123"
          put "/jimmy/documents/bar", "another text"

          last_response.status.must_equal 200
          storage_client.bucket("user_data").get("jimmy:documents:bar").data.must_equal "another text"
        end
      end

      describe "DELETE" do
        it "removes the key" do
          header "Authorization", "Bearer 123"
          delete "/jimmy/documents/foo"

          last_response.status.must_equal 204
          lambda {storage_client.bucket("user_data").get("jimmy:documents:foo")}.must_raise Riak::HTTPFailedRequest
        end
      end
    end

    describe "unauthorized access" do
      before do
        auth = storage_client.bucket("authorizations").new("jimmy:123")
        auth.data = ["documents", "public"]
        auth.store

        header "Authorization", "Bearer 321"
      end

      describe "GET" do
        it "returns a 403" do
          get "/jimmy/documents/foo"

          last_response.status.must_equal 403
        end
      end

      describe "PUT" do
        it "returns a 403" do
          put "/jimmy/documents/foo", "some text"

          last_response.status.must_equal 403
        end
      end

      describe "DELETE" do
        it "returns a 403" do
          delete "/jimmy/documents/foo"

          last_response.status.must_equal 403
        end
      end
    end
  end

else

  $stderr.puts "INFO: skipping riak spec, as it's not configured."

end
