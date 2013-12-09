require_relative "spec_helper"

describe "App with Riak backend" do
  include Rack::Test::Methods

  before do
    purge_all_buckets
  end

  describe "GET public data" do
    before do
      object = data_bucket.new("jimmy:public:foo")
      object.content_type = "text/plain"
      object.data = "some text data"
      object.store

      get "/jimmy/public/foo"
    end

    it "returns the value on all get requests" do
      last_response.status.must_equal 200
      last_response.body.must_equal "some text data"
    end

    # If this one fails, try restarting Riak
    it "has a Last-Modified header set" do
      last_response.status.must_equal 200
      last_response.headers["Last-Modified"].wont_be_nil

      now = Time.now
      last_modified = DateTime.parse(last_response.headers["Last-Modified"])
      last_modified.year.must_equal now.year
      last_modified.day.must_equal now.day
    end

    it "has an ETag header set" do
      last_response.status.must_equal 200
      last_response.headers["ETag"].wont_be_nil
    end

    it "has caching headers set" do
      last_response.status.must_equal 200
      last_response.headers["Expires"].must_equal "0"
    end
  end

  describe "GET data with custom content type" do
    before do
      object = data_bucket.new("jimmy:public:magic")
      object.content_type = "text/magic"
      object.raw_data = "some text data"
      object.store
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
      object = data_bucket.new("jimmy:documents:foo")
      object.content_type = "text/plain"
      object.data = "some private text data"
      object.store

      @etag = object.etag

      auth = auth_bucket.new("jimmy:123")
      auth.data = ["documents", "public"]
      auth.store
    end

    describe "GET" do
      before do
        header "Authorization", "Bearer 123"
      end

      it "returns the value" do
        get "/jimmy/documents/foo"

        last_response.status.must_equal 200
        last_response.body.must_equal "some private text data"
      end

      describe "when If-None-Match header is set" do
        it "responds with 'not modified' when it matches the current ETag" do
          header "If-None-Match", @etag
          get "/jimmy/documents/foo"

          last_response.status.must_equal 304
          last_response.body.must_be_empty
          last_response.headers["ETag"].must_equal @etag
        end

        it "responds normally when it does not match the current ETag" do
          header "If-None-Match", "FOO"
          get "/jimmy/documents/foo"

          last_response.status.must_equal 200
          last_response.body.must_equal "some private text data"
        end
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
      before do
        header "Authorization", "Bearer 123"
      end

      describe "with implicit content type" do
        before do
          put "/jimmy/documents/bar", "another text"
        end

        it "saves the value" do
          last_response.status.must_equal 201
          last_response.body.must_equal ""
          data_bucket.get("jimmy:documents:bar").data.must_equal "another text"
        end

        it "stores the data as plain text with utf-8 encoding" do
          data_bucket.get("jimmy:documents:bar").content_type.must_equal "text/plain; charset=utf-8"
        end

        it "sets the ETag header" do
          last_response.headers["ETag"].wont_be_nil
        end

        it "indexes the data set" do
          indexes = data_bucket.get("jimmy:documents:bar").indexes
          indexes["user_id_bin"].must_be_kind_of Set
          indexes["user_id_bin"].must_include "jimmy"

          indexes["directory_bin"].must_include "documents"
        end

        it "logs the operation" do
          objects = []
          opslog_bucket.keys.each { |k| objects << opslog_bucket.get(k) rescue nil }

          log_entry = objects.select{|o| o.data["count"] == 1}.first
          log_entry.data["size"].must_equal 12
          log_entry.data["category"].must_equal "documents"
          log_entry.indexes["user_id_bin"].must_include "jimmy"
        end
      end

      describe "with explicit content type" do
        before do
          header "Content-Type", "application/json"
          put "/jimmy/documents/jason", '{"foo": "bar", "unhosted": 1}'
        end

        it "saves the value (as JSON)" do
          last_response.status.must_equal 201
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
          header "Content-Type", "text/magic"
          put "/jimmy/documents/magic", "pure magic"
        end

        it "saves the value" do
          last_response.status.must_equal 201
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

      describe "with content type containing the encoding" do
        before do
          header "Content-Type", "application/json; charset=UTF-8"
          put "/jimmy/documents/jason", '{"foo": "bar", "unhosted": 1}'
        end

        it "saves the value (as JSON)" do
          last_response.status.must_equal 201
          data_bucket.get("jimmy:documents:jason").data.must_be_kind_of Hash
          data_bucket.get("jimmy:documents:jason").data.must_equal({"foo" => "bar", "unhosted" => 1})
        end

        it "uses the requested content type" do
          data_bucket.get("jimmy:documents:jason").content_type.must_equal "application/json; charset=UTF-8"
        end

        it "delivers the data correctly" do
          get "/jimmy/documents/jason"

          last_response.body.must_equal '{"foo":"bar","unhosted":1}'
          last_response.content_type.must_equal "application/json; charset=UTF-8"
        end
      end

      describe "with existing content" do
        before do
          put "/jimmy/documents/archive/foo", "lorem ipsum"
        end

        it "saves the value" do
          put "/jimmy/documents/archive/foo", "some awesome content"

          last_response.status.must_equal 200
          data_bucket.get("jimmy:documents/archive:foo").data.must_equal "some awesome content"
        end

        it "logs the operations" do
          put "/jimmy/documents/archive/foo", "some awesome content"

          objects = []
          opslog_bucket.keys.each { |k| objects << opslog_bucket.get(k) rescue nil }

          create_entry = objects.select{|o| o.data["count"] == 1}.first
          create_entry.data["size"].must_equal 11
          create_entry.data["category"].must_equal "documents"
          create_entry.indexes["user_id_bin"].must_include "jimmy"

          update_entry = objects.select{|o| o.data["count"] == 0}.first
          update_entry.data["size"].must_equal 9
          update_entry.data["category"].must_equal "documents"
          update_entry.indexes["user_id_bin"].must_include "jimmy"
        end

        it "changes the ETag header" do
          old_etag = last_response.headers["ETag"]
          put "/jimmy/documents/archive/foo", "some awesome content"

          last_response.headers["ETag"].wont_be_nil
          last_response.headers["ETag"].wont_equal old_etag
        end

        describe "when If-Match header is set" do
          it "allows the request if the header matches the current ETag" do
            old_etag = last_response.headers["ETag"]
            header "If-Match", old_etag

            put "/jimmy/documents/archive/foo", "some awesome content"
            last_response.status.must_equal 200

            get "/jimmy/documents/archive/foo"
            last_response.body.must_equal "some awesome content"
          end

          it "fails the request if the header does not match the current ETag" do
            header "If-Match", "WONTMATCH"

            put "/jimmy/documents/archive/foo", "some awesome content"
            last_response.status.must_equal 412

            get "/jimmy/documents/archive/foo"
            last_response.body.must_equal "lorem ipsum"
          end
        end

        describe "when If-None-Match header is set" do
          before do
            header "If-None-Match", "*"
          end

          it "fails when the document already exists" do
            put "/jimmy/documents/archive/foo", "some awesome content"

            last_response.status.must_equal 412

            get "/jimmy/documents/archive/foo"
            last_response.body.must_equal "lorem ipsum"
          end

          it "succeeds when the document does not exist" do
            put "/jimmy/documents/archive/bar", "my little content"

            last_response.status.must_equal 201
          end
        end
      end

      describe "exsting content without serializer registered for the given content-type" do
        before do
          header "Content-Type", "text/html; charset=UTF-8"
          put "/jimmy/documents/html", '<html></html>'
          put "/jimmy/documents/html", '<html><body></body></html>'
        end

        it "saves the value" do
          last_response.status.must_equal 200
          data_bucket.get("jimmy:documents:html").raw_data.must_equal "<html><body></body></html>"
        end

        it "uses the requested content type" do
          data_bucket.get("jimmy:documents:html").content_type.must_equal "text/html; charset=UTF-8"
        end
      end

      describe "public data" do
        before do
          put "/jimmy/public/documents/notes/foo", "note to self"
        end

        it "saves the value" do
          last_response.status.must_equal 201
          data_bucket.get("jimmy:public/documents/notes:foo").data.must_equal "note to self"
        end

        it "logs the operation" do
          objects = []
          opslog_bucket.keys.each { |k| objects << opslog_bucket.get(k) rescue nil }

          log_entry = objects.select{|o| o.data["count"] == 1}.first
          log_entry.data["size"].must_equal 12
          log_entry.data["category"].must_equal "public/documents"
          log_entry.indexes["user_id_bin"].must_include "jimmy"
        end
      end

      context "with binary data" do
        context "binary charset in content-type header" do
          before do
            header "Content-Type", "image/jpeg; charset=binary"
            filename = File.join(File.expand_path(File.dirname(__FILE__)), "fixtures", "rockrule.jpeg")
            @image = File.open(filename, "r").read
            put "/jimmy/documents/jaypeg", @image
          end

          it "uses the requested content type" do
            get "/jimmy/documents/jaypeg"

            last_response.status.must_equal 200
            last_response.content_type.must_equal "image/jpeg; charset=binary"
          end

          it "delivers the data correctly" do
            get "/jimmy/documents/jaypeg"

            last_response.status.must_equal 200
            last_response.body.must_equal @image
          end

          it "responds with an ETag header" do
            last_response.headers["ETag"].wont_be_nil
            etag = last_response.headers["ETag"]

            get "/jimmy/documents/jaypeg"

            last_response.headers["ETag"].wont_be_nil
            last_response.headers["ETag"].must_equal etag
          end

          it "changes the ETag when updating the file" do
            old_etag = last_response.headers["ETag"]
            put "/jimmy/documents/jaypeg", @image

            last_response.headers["ETag"].wont_be_nil
            last_response.headers["ETag"].wont_equal old_etag
          end

          it "logs the operation" do
            objects = []
            opslog_bucket.keys.each { |k| objects << opslog_bucket.get(k) rescue nil }

            log_entry = objects.select{|o| o.data["count"] == 1}.first
            log_entry.data["size"].must_equal 16044
            log_entry.data["category"].must_equal "documents"
            log_entry.indexes["user_id_bin"].must_include "jimmy"
          end

          context "overwriting existing file with same file" do
            before do
              header "Content-Type", "image/jpeg; charset=binary"
              filename = File.join(File.expand_path(File.dirname(__FILE__)), "fixtures", "rockrule.jpeg")
              @image = File.open(filename, "r").read
              put "/jimmy/documents/jaypeg", @image
            end

            it "doesn't log the operation" do
              objects = []
              opslog_bucket.keys.each { |k| objects << opslog_bucket.get(k) rescue nil }

              objects.size.must_equal 1
            end
          end

          context "overwriting existing file with different file" do
            before do
              header "Content-Type", "image/jpeg; charset=binary"
              filename = File.join(File.expand_path(File.dirname(__FILE__)), "fixtures", "rockrule.jpeg")
              @image = File.open(filename, "r").read
              put "/jimmy/documents/jaypeg", @image+"foo"
            end

            it "logs the operation changing only the size" do
              objects = []
              opslog_bucket.keys.each { |k| objects << opslog_bucket.get(k) rescue nil }

              objects.size.must_equal 2

              log_entry = objects.select{|o| o.data["count"] == 0}.first
              log_entry.data["size"].must_equal 3
              log_entry.data["category"].must_equal "documents"
              log_entry.indexes["user_id_bin"].must_include "jimmy"
            end
          end
        end

        context "no binary charset in content-type header" do
          before do
            header "Content-Type", "image/jpeg"
            filename = File.join(File.expand_path(File.dirname(__FILE__)), "fixtures", "rockrule.jpeg")
            @image = File.open(filename, "r").read
            put "/jimmy/documents/jaypeg", @image
          end

          it "uses the requested content type" do
            get "/jimmy/documents/jaypeg"

            last_response.status.must_equal 200
            last_response.content_type.must_equal "image/jpeg"
          end

          it "delivers the data correctly" do
            get "/jimmy/documents/jaypeg"

            last_response.status.must_equal 200
            last_response.body.must_equal @image
          end
        end
      end

      context "with escaped key" do
        before do
          put "/jimmy/documents/http%3A%2F%2F5apps.com", "super website"
        end

        it "delivers the data correctly" do
          header "Authorization", "Bearer 123"
          get "/jimmy/documents/http%3A%2F%2F5apps.com"

          last_response.body.must_equal 'super website'
        end
      end

      context "escaped square brackets in key" do
        before do
          put "/jimmy/documents/gracehopper%5B1%5D.jpg", "super image"
        end

        it "delivers the data correctly" do
          header "Authorization", "Bearer 123"
          get "/jimmy/documents/gracehopper%5B1%5D.jpg"

          last_response.body.must_equal "super image"
        end
      end

      context "invalid JSON" do
        context "empty body" do
          before do
            header "Content-Type", "application/json"
            put "/jimmy/documents/jason", ""
          end

          it "saves an empty JSON object" do
            last_response.status.must_equal 201
            data_bucket.get("jimmy:documents:jason").data.must_be_kind_of Hash
            data_bucket.get("jimmy:documents:jason").data.must_equal({})
          end
        end

        context "unparsable JSON" do
          before do
            header "Content-Type", "application/json"
            put "/jimmy/documents/jason", "foo"
          end

          it "returns a 422" do
            last_response.status.must_equal 422
          end
        end
      end
    end

    describe "DELETE" do
      before do
        header "Authorization", "Bearer 123"
      end

      describe "basics" do
        before do
          delete "/jimmy/documents/foo"
        end

        it "removes the key" do
          last_response.status.must_equal 200
          lambda {
            data_bucket.get("jimmy:documents:foo")
          }.must_raise Riak::HTTPFailedRequest
        end

        it "logs the operation" do
          objects = []
          opslog_bucket.keys.each { |k| objects << opslog_bucket.get(k) rescue nil }

          log_entry = objects.select{|o| o.data["count"] == -1}.first
          log_entry.data["size"].must_equal(-22)
          log_entry.data["category"].must_equal "documents"
          log_entry.indexes["user_id_bin"].must_include "jimmy"
        end
      end

      context "non-existing object" do
        before do
          delete "/jimmy/documents/foozius"
        end

        it "responds with 404" do
          last_response.status.must_equal 404
        end

        it "doesn't log the operation" do
          objects = []
          opslog_bucket.keys.each { |k| objects << opslog_bucket.get(k) rescue nil }
          objects.select{|o| o.data["count"] == -1}.size.must_equal 0
        end
      end

      context "when an If-Match header is given" do
        it "allows the request if it matches the current ETag" do
          get "/jimmy/documents/foo"
          old_etag = last_response.headers["ETag"]
          header "If-Match", old_etag

          delete "/jimmy/documents/foo"
          last_response.status.must_equal 200

          get "/jimmy/documents/foo"
          last_response.status.must_equal 404
        end

        it "fails the request if it does not match the current ETag" do
          header "If-Match", "WONTMATCH"

          delete "/jimmy/documents/foo"
          last_response.status.must_equal 412

          get "/jimmy/documents/foo"
          last_response.status.must_equal 200
          last_response.body.must_equal "some private text data"
        end
      end

      context "binary data" do
        before do
          header "Content-Type", "image/jpeg; charset=binary"
          filename = File.join(File.expand_path(File.dirname(__FILE__)), "fixtures", "rockrule.jpeg")
          @image = File.open(filename, "r").read
          put "/jimmy/documents/jaypeg", @image

          delete "/jimmy/documents/jaypeg"
        end

        it "removes the main object" do
          last_response.status.must_equal 200
          lambda {
            data_bucket.get("jimmy:documents:jaypeg")
          }.must_raise Riak::HTTPFailedRequest
        end

        it "removes the binary object" do
          last_response.status.must_equal 200

          binary = cs_binary_bucket.files.get("jimmy:documents:jaypeg")
          binary.must_be_nil
        end

        it "logs the operation" do
          objects = []
          opslog_bucket.keys.each { |k| objects << opslog_bucket.get(k) rescue nil }

          log_entry = objects.select{|o| o.data["count"] == -1 && o.data["size"] == -16044}.first
          log_entry.data["category"].must_equal "documents"
          log_entry.indexes["user_id_bin"].must_include "jimmy"
        end
      end
    end
  end

  describe "unauthorized access" do
    before do
      auth = auth_bucket.new("jimmy:123")
      auth.data = ["documents", "public"]
      auth.store

      header "Authorization", "Bearer 321"
    end

    describe "GET" do
      it "returns a 401" do
        get "/jimmy/documents/foo"

        last_response.status.must_equal 401
      end
    end

    describe "PUT" do
      it "returns a 401" do
        put "/jimmy/documents/foo", "some text"

        last_response.status.must_equal 401
      end
    end

    describe "DELETE" do
      it "returns a 401" do
        delete "/jimmy/documents/foo"

        last_response.status.must_equal 401
      end
    end
  end
end
