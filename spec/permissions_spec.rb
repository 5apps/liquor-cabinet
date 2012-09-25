require_relative "spec_helper"

describe "Permissions" do
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

  def auth_bucket
    @auth_bucket ||= storage_client.bucket("authorizations")
  end

  describe "public data" do
    describe "GET" do
      before do
        object = data_bucket.new("jimmy:public:foo")
        object.content_type = "text/plain"
        object.data = "some text data"
        object.store

        object = data_bucket.new("jimmy:public/documents:foo")
        object.content_type = "text/plain"
        object.data = "some text data"
        object.store
      end

      after do
        data_bucket.delete("jimmy:public:foo")
        data_bucket.delete("jimmy:public/documents:foo")
      end

      it "returns the value on all get requests" do
        get "/jimmy/public/foo"

        last_response.status.must_equal 200
        last_response.body.must_equal "some text data"

        last_response.headers["Last-Modified"].wont_be_nil
      end

      it "returns the value from a sub-directory" do
        get "/jimmy/public/documents/foo"

        last_response.status.must_equal 200
        last_response.body.must_equal "some text data"
      end
    end
  end

  describe "private data" do
    describe "GET" do
      before do
        object = data_bucket.new("jimmy:documents:foo")
        object.content_type = "text/plain"
        object.data = "some private, authorized text data"
        object.store

        object = data_bucket.new("jimmy:documents/very/interesting:text")
        object.content_type = "text/plain"
        object.data = "some very interesting writing"
        object.store

        object = data_bucket.new("jimmy:confidential:bar")
        object.content_type = "text/plain"
        object.data = "some private, non-authorized text data"
        object.store

        auth = auth_bucket.new("jimmy:123")
        auth.data = ["documents:r", "tasks:rw"]
        auth.store

        header "Authorization", "Bearer 123"
      end

      after do
        data_bucket.delete("jimmy:documents:foo")
        data_bucket.delete("jimmy:documents/very/interesting:text")
        data_bucket.delete("jimmy:confidential:bar")
        auth_bucket.delete("jimmy:123")
      end

      describe "when authorized" do
        it "returns the value for a key in a top-level directory" do
          get "/jimmy/documents/foo"

          last_response.status.must_equal 200
          last_response.body.must_equal "some private, authorized text data"
        end

        it "returns the value for a key in a sub-directory" do
          get "/jimmy/documents/very/interesting/text"

          last_response.status.must_equal 200
          last_response.body.must_equal "some very interesting writing"
        end
      end

      describe "when not authorized" do
        it "returns a 403 for a key in a top-level directory" do
          get "/jimmy/confidential/bar"

          last_response.status.must_equal 403
        end
      end
    end

    describe "PUT" do
      before do
        auth = auth_bucket.new("jimmy:123")
        auth.data = ["documents:r", "contacts:rw", "tasks:r", "tasks/home:rw"]
        auth.store

        header "Authorization", "Bearer 123"
      end

      after do
        auth_bucket.delete("jimmy:123")
      end

      describe "to a top-level directory" do
        after do
          data_bucket.delete("jimmy:contacts:1")
        end

        it "saves the value when there are write permissions" do
          put "/jimmy/contacts/1", "John Doe"

          last_response.status.must_equal 200
          data_bucket.get("jimmy:contacts:1").data.must_equal "John Doe"
        end

        it "returns a 403 when there are read permissions only" do
          put "/jimmy/documents/foo", "some text"

          last_response.status.must_equal 403
        end
      end

      describe "to a sub-directory" do
        after do
          data_bucket.delete("jimmy:tasks/home:1")
          data_bucket.delete("jimmy:contacts/family:1")
        end

        it "saves the value when there are direct write permissions" do
          put "/jimmy/tasks/home/1", "take out the trash"

          last_response.status.must_equal 200
          data_bucket.get("jimmy:tasks/home:1").data.must_equal "take out the trash"
        end

        it "saves the value when there are write permissions for a parent directory" do
          put "/jimmy/contacts/family/1", "Bobby Brother"

          last_response.status.must_equal 200
          data_bucket.get("jimmy:contacts/family:1").data.must_equal "Bobby Brother"
        end

        it "returns a 403 when there are read permissions only" do
          put "/jimmy/documents/business/1", "some text"

          last_response.status.must_equal 403
        end
      end
    end

    describe "DELETE" do
      before do
        auth = auth_bucket.new("jimmy:123")
        auth.data = ["documents:r", "tasks:rw"]
        auth.store

        header "Authorization", "Bearer 123"
      end

      after do
        auth_bucket.delete("jimmy:123")
      end

      describe "when authorized" do
        before do
          object = data_bucket.new("jimmy:tasks:1")
          object.content_type = "text/plain"
          object.data = "do the laundry"
          object.store

          object = data_bucket.new("jimmy:tasks/home:1")
          object.content_type = "text/plain"
          object.data = "take out the trash"
          object.store
        end

        it "removes the key from a top-level directory" do
          delete "/jimmy/tasks/1"

          last_response.status.must_equal 204
          lambda {
            data_bucket.get("jimmy:tasks:1")
          }.must_raise Riak::HTTPFailedRequest
        end

        it "removes the key from a top-level directory" do
          delete "/jimmy/tasks/home/1"

          last_response.status.must_equal 204
          lambda {
            data_bucket.get("jimmy:tasks/home:1")
          }.must_raise Riak::HTTPFailedRequest
        end
      end

      describe "when not authorized" do
        before do
          object = data_bucket.new("jimmy:documents:private")
          object.content_type = "text/plain"
          object.data = "some private, authorized text data"
          object.store

          object = data_bucket.new("jimmy:documents/business:foo")
          object.content_type = "text/plain"
          object.data = "some private, authorized text data"
          object.store
        end

        after do
          data_bucket.delete("jimmy:documents:private")
          data_bucket.delete("jimmy:documents/business:foo")
        end

        it "returns a 403 for a key in a top-level directory" do
          delete "/jimmy/documents/private"

          last_response.status.must_equal 403
        end

        it "returns a 403 for a key in a sub-directory" do
          delete "/jimmy/documents/business/foo"

          last_response.status.must_equal 403
        end
      end
    end
  end

  describe "global permissions" do
    before do
      object = data_bucket.new("jimmy:documents/very/interesting:text")
      object.content_type = "text/plain"
      object.data = "some very interesting writing"
      object.store
    end

    after do
      data_bucket.delete("jimmy:documents/very/interesting:text")
    end

    describe "write all" do
      before do
        auth = auth_bucket.new("jimmy:123")
        auth.data = [":rw", "documents:r"]
        auth.store

        header "Authorization", "Bearer 123"
      end

      after do
        auth_bucket.delete("jimmy:123")
        data_bucket.delete("jimmy:contacts:1")
      end

      it "allows GET requests" do
        get "/jimmy/documents/very/interesting/text"

        last_response.status.must_equal 200
        last_response.body.must_equal "some very interesting writing"
      end

      it "allows PUT requests" do
        put "/jimmy/contacts/1", "John Doe"

        last_response.status.must_equal 200
        data_bucket.get("jimmy:contacts:1").data.must_equal "John Doe"
      end

      it "allows DELETE requests" do
        delete "/jimmy/documents/very/interesting/text"

        last_response.status.must_equal 204
        lambda {
          data_bucket.get("jimmy:documents/very/interesting:text")
        }.must_raise Riak::HTTPFailedRequest
      end
    end

    describe "read all" do
      before do
        auth = auth_bucket.new("jimmy:123")
        auth.data = [":r", "contacts:rw"]
        auth.store

        header "Authorization", "Bearer 123"
      end

      after do
        auth_bucket.delete("jimmy:123")
      end

      it "allows GET requests" do
        get "/jimmy/documents/very/interesting/text"

        last_response.status.must_equal 200
        last_response.body.must_equal "some very interesting writing"
      end

      it "disallows PUT requests" do
        put "/jimmy/documents/foo", "some text"

        last_response.status.must_equal 403
      end

      it "disallows DELETE requests" do
        delete "/jimmy/documents/very/interesting/text"

        last_response.status.must_equal 403
      end
    end
  end

end
