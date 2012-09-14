require_relative "spec_helper"

describe "App with Riak backend" do
  include Rack::Test::Methods
  include RemoteStorage::Riak

  def app
    LiquorCabinet
  end

  def storage_client
    @storage_client ||= ::Riak::Client.new(settings.riak_config)
  end

  def data_bucket
    @data_bucket ||= storage_client.bucket("user_data")
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

  describe "GET data with custom content type" do
    before do
      object = data_bucket.new("jimmy:public:magic")
      object.content_type = "text/magic"
      object.raw_data = "some text data"
      object.store
    end

    after do
      data_bucket.delete("jimmy:public:magic")
    end

    it "returns the value with the correct content type" do
      get "/jimmy/public/magic"

      last_response.status.must_equal 200
      last_response.content_type.must_equal "text/magic"
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
      describe "with implicit content type" do
        before do
          header "Authorization", "Bearer 123"
          put "/jimmy/documents/bar", "another text"
        end

        it "saves the value" do
          last_response.status.must_equal 200
          data_bucket.get("jimmy:documents:bar").data.must_equal "another text"
        end

        it "stores the data as plain text with utf-8 encoding" do
          data_bucket.get("jimmy:documents:bar").content_type.must_equal "text/plain; charset=utf-8"
        end

        it "indexes the data set" do
          data_bucket.get("jimmy:documents:bar").indexes["user_id_bin"].must_be_kind_of Set
          data_bucket.get("jimmy:documents:bar").indexes["user_id_bin"].must_include "jimmy"
        end
      end

      describe "with explicit content type" do
        before do
          header "Authorization", "Bearer 123"
          header "Content-Type", "application/json"
          put "/jimmy/documents/jason", '{"foo": "bar", "unhosted": 1}'
        end

        it "saves the value (as JSON)" do
          last_response.status.must_equal 200
          data_bucket.get("jimmy:documents:jason").data.must_be_kind_of Hash
          data_bucket.get("jimmy:documents:jason").data.must_equal({"foo" => "bar", "unhosted" => 1})
        end

        it "uses the requested content type" do
          data_bucket.get("jimmy:documents:jason").content_type.must_equal "application/json"
        end

        it "delivers the data correctly" do
          header "Authorization", "Bearer 123"
          get "/jimmy/documents/jason"

          last_response.body.must_equal '{"foo":"bar","unhosted":1}'
          last_response.content_type.must_equal "application/json"
        end
      end

      describe "with arbitrary content type" do
        before do
          header "Authorization", "Bearer 123"
          header "Content-Type", "text/magic"
          put "/jimmy/documents/magic", "pure magic"
        end

        after do
          data_bucket.delete("jimmy:documents:magic")
        end

        it "saves the value" do
          last_response.status.must_equal 200
          data_bucket.get("jimmy:documents:magic").raw_data.must_equal "pure magic"
        end

        it "uses the requested content type" do
          data_bucket.get("jimmy:documents:magic").content_type.must_equal "text/magic"
        end

        it "delivers the data correctly" do
          header "Authorization", "Bearer 123"
          get "/jimmy/documents/magic"

          last_response.body.must_equal "pure magic"
          last_response.content_type.must_equal "text/magic"
        end
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
