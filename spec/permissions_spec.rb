require_relative "spec_helper"

describe "Permissions" do
  include Rack::Test::Methods
  include RemoteStorage::Riak

  before do
    purge_all_buckets
  end

  describe "GET" do
    context "public data" do
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

    context "private data" do
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

      context "when authorized" do
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

      context "when not authorized" do
        it "returns a 403 for a key in a top-level directory" do
          get "/jimmy/confidential/bar"

          last_response.status.must_equal 403
        end
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

    context "to a top-level directory" do
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

    context "to a sub-directory" do
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

    context "to the public directory" do
      context "when authorized for the corresponding category" do
        it "saves the value" do
          put "/jimmy/public/contacts/foo", "Foo Bar"

          last_response.status.must_equal 200
          data_bucket.get("jimmy:public/contacts:foo").data.must_equal "Foo Bar"
        end

        it "saves the value to a sub-directory" do
          put "/jimmy/public/contacts/family/foo", "Foo Bar"

          last_response.status.must_equal 200
          data_bucket.get("jimmy:public/contacts/family:foo").data.must_equal "Foo Bar"
        end
      end

      context "when not authorized for the corresponding category" do
        it "returns a 403" do
          put "/jimmy/public/documents/foo", "Foo Bar"

          last_response.status.must_equal 403
        end
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

    context "when authorized" do
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

      context "public directory" do
        before do
          object = data_bucket.new("jimmy:public/tasks:open")
          object.content_type = "text/plain"
          object.data = "hello world"
          object.store
        end

        it "removes the key" do
          delete "/jimmy/public/tasks/open"

          last_response.status.must_equal 204
          lambda {
            data_bucket.get("jimmy:public/tasks:open")
          }.must_raise Riak::HTTPFailedRequest
        end
      end
    end

    context "when not authorized" do
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

      it "returns a 403 for a key in a top-level directory" do
        delete "/jimmy/documents/private"

        last_response.status.must_equal 403
      end

      it "returns a 403 for a key in a sub-directory" do
        delete "/jimmy/documents/business/foo"

        last_response.status.must_equal 403
      end

      context "public directory" do
        before do
          object = data_bucket.new("jimmy:public/documents:foo")
          object.content_type = "text/plain"
          object.data = "some private, authorized text data"
          object.store
        end

        it "returns a 403" do
          delete "/jimmy/public/documents/foo"

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

    context "write all" do
      before do
        auth = auth_bucket.new("jimmy:123")
        auth.data = [":rw", "documents:r"]
        auth.store

        header "Authorization", "Bearer 123"
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

      context "root directory" do
        before do
          object = data_bucket.new("jimmy::root")
          object.content_type = "text/plain"
          object.data = "Back to the roots"
          object.store
        end

        it "allows GET requests" do
          get "/jimmy/root"

          last_response.status.must_equal 200
          last_response.body.must_equal "Back to the roots"
        end

        it "allows PUT requests" do
          put "/jimmy/1", "Gonna kick it root down"

          last_response.status.must_equal 200
          data_bucket.get("jimmy::1").data.must_equal "Gonna kick it root down"
        end

        it "allows DELETE requests" do
          delete "/jimmy/root"

          last_response.status.must_equal 204
          lambda {
            data_bucket.get("jimmy::root")
          }.must_raise Riak::HTTPFailedRequest
        end
      end

      context "public directory" do
        before do
          object = data_bucket.new("jimmy:public/tasks:hello")
          object.content_type = "text/plain"
          object.data = "Hello World"
          object.store
        end

        it "allows GET requests" do
          get "/jimmy/public/tasks/"

          last_response.status.must_equal 200
        end

        it "allows PUT requests" do
          put "/jimmy/public/1", "Hello World"

          last_response.status.must_equal 200
          data_bucket.get("jimmy:public:1").data.must_equal "Hello World"
        end

        it "allows DELETE requests" do
          delete "/jimmy/public/tasks/hello"

          last_response.status.must_equal 204
          lambda {
            data_bucket.get("jimmy:public/tasks:hello")
          }.must_raise Riak::HTTPFailedRequest
        end
      end
    end

    context "read all" do
      before do
        auth = auth_bucket.new("jimmy:123")
        auth.data = [":r", "contacts:rw"]
        auth.store

        header "Authorization", "Bearer 123"
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

      context "public directory" do
        before do
          object = data_bucket.new("jimmy:public/tasks:hello")
          object.content_type = "text/plain"
          object.data = "Hello World"
          object.store
        end

        it "allows GET requests" do
          get "/jimmy/tasks/"

          last_response.status.must_equal 200
        end

        it "disallows PUT requests" do
          put "/jimmy/tasks/foo", "some text"

          last_response.status.must_equal 403
        end

        it "disallows DELETE requests" do
          delete "/jimmy/tasks/hello"

          last_response.status.must_equal 403
        end
      end
    end
  end

end
