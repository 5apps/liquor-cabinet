require_relative "spec_helper"

describe "Directories" do
  include Rack::Test::Methods

  before do
    purge_all_buckets

    auth = auth_bucket.new("jimmy:123")
    auth.data = [":r", "documents:r", "tasks:rw"]
    auth.store

    header "Authorization", "Bearer 123"
  end

  describe "HEAD listing" do
    before do
      put "/jimmy/tasks/foo", "do the laundry"
      put "/jimmy/tasks/http%3A%2F%2F5apps.com", "prettify design"

      head "/jimmy/tasks/"
    end

    it "has an empty body" do
      last_response.status.must_equal 200
      last_response.body.must_equal ""
    end

    it "has a Last-Modifier header set" do
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

      # check that ETag stays the same
      etag = last_response.headers["ETag"]
      get "/jimmy/tasks/"
      last_response.headers["ETag"].must_equal etag
    end

    it "has CORS headers set" do
      last_response.status.must_equal 200
      last_response.headers["Access-Control-Allow-Origin"].must_equal "*"
      last_response.headers["Access-Control-Allow-Methods"].must_equal "GET, PUT, DELETE"
      last_response.headers["Access-Control-Allow-Headers"].must_equal "Authorization, Content-Type, Origin, If-Match, If-None-Match"
      last_response.headers["Access-Control-Expose-Headers"].must_equal "ETag"
    end

    context "for an empty or absent directory" do
      it "responds with 404" do
        head "/jimmy/documents/"

        last_response.status.must_equal 404
      end
    end
  end

  describe "GET listing" do
    before do
      put "/jimmy/tasks/foo", "do the laundry"
      put "/jimmy/tasks/http%3A%2F%2F5apps.com", "prettify design"
    end

    it "lists the objects with version, length and content-type" do
      get "/jimmy/tasks/"

      last_response.status.must_equal 200
      last_response.content_type.must_equal "application/json"

      foo = data_bucket.get("jimmy:tasks:foo")

      content = JSON.parse(last_response.body)
      content["items"]["http://5apps.com"].wont_be_nil
      content["items"]["foo"].wont_be_nil
      content["items"]["foo"]["ETag"].must_equal foo.etag.gsub(/"/, "")
      content["items"]["foo"]["Content-Type"].must_equal "text/plain"
      content["items"]["foo"]["Content-Length"].must_equal 14
    end

    it "has a Last-Modifier header set" do
      get "/jimmy/tasks/"

      last_response.status.must_equal 200
      last_response.headers["Last-Modified"].wont_be_nil

      now = Time.now
      last_modified = DateTime.parse(last_response.headers["Last-Modified"])
      last_modified.year.must_equal now.year
      last_modified.day.must_equal now.day
    end

    it "has an ETag header set" do
      get "/jimmy/tasks/"

      last_response.status.must_equal 200
      last_response.headers["ETag"].wont_be_nil

      # check that ETag stays the same
      etag = last_response.headers["ETag"]
      get "/jimmy/tasks/"
      last_response.headers["ETag"].must_equal etag
    end

    it "has CORS headers set" do
      get "/jimmy/tasks/"

      last_response.status.must_equal 200
      last_response.headers["Access-Control-Allow-Origin"].must_equal "*"
      last_response.headers["Access-Control-Allow-Methods"].must_equal "GET, PUT, DELETE"
      last_response.headers["Access-Control-Allow-Headers"].must_equal "Authorization, Content-Type, Origin, If-Match, If-None-Match"
      last_response.headers["Access-Control-Expose-Headers"].must_equal "ETag"
    end

    it "has caching headers set" do
      get "/jimmy/tasks/"

      last_response.status.must_equal 200
      last_response.headers["Expires"].must_equal "0"
    end

    context "when If-None-Match header is set" do
      before do
        get "/jimmy/tasks/"

        @etag = last_response.headers["ETag"]
      end

      it "responds with 'not modified' when it matches the current ETag" do
        header "If-None-Match", @etag
        get "/jimmy/tasks/"

        last_response.status.must_equal 304
        last_response.body.must_be_empty
        last_response.headers["ETag"].must_equal @etag
      end

      it "responds normally when it does not match the current ETag" do
        header "If-None-Match", "FOO"
        get "/jimmy/tasks/"

        last_response.status.must_equal 200
        last_response.body.wont_be_empty
      end
    end

    context "with sub-directories" do
      before do
        get "/jimmy/tasks/"
        @old_etag = last_response.headers["ETag"]

        put "/jimmy/tasks/home/laundry", "do the laundry"
      end

      it "lists the containing objects as well as the direct sub-directories" do
        get "/jimmy/tasks/"

        last_response.status.must_equal 200

        home = directory_bucket.get("jimmy:tasks/home")

        content = JSON.parse(last_response.body)
        content["items"]["foo"].wont_be_nil
        content["items"]["http://5apps.com"].wont_be_nil
        content["items"]["home/"].wont_be_nil
        content["items"]["home/"]["ETag"].must_equal home.etag.gsub(/"/, "")
      end

      it "updates the ETag of the parent directory" do
        get "/jimmy/tasks/"

        last_response.headers["ETag"].wont_be_nil
        last_response.headers["ETag"].wont_equal @old_etag
      end

      context "for a different user" do
        before do
          auth = auth_bucket.new("alice:321")
          auth.data = [":r", "documents:r", "tasks:rw"]
          auth.store

          header "Authorization", "Bearer 321"

          put "/alice/tasks/homework", "write an essay"
        end

        it "does not list the directories of jimmy" do
          get "/alice/tasks/"

          last_response.status.must_equal 200

          content = JSON.parse(last_response.body)
          content["items"]["/"].must_be_nil
          content["items"]["tasks/"].must_be_nil
          content["items"]["home/"].must_be_nil
          content["items"]["homework"].wont_be_nil
        end
      end

      context "sub-directories without objects" do
        it "lists the direct sub-directories" do
          put "/jimmy/tasks/private/projects/world-domination/start", "write a manifesto"
          get "/jimmy/tasks/private/"

          last_response.status.must_equal 200

          projects = directory_bucket.get("jimmy:tasks/private/projects")

          content = JSON.parse(last_response.body)
          content["items"]["projects/"]["ETag"].must_equal projects.etag.gsub(/"/, "")
        end

        it "updates the timestamps of the existing directory objects" do
          directory = directory_bucket.new("jimmy:tasks")
          directory.content_type = "text/plain"
          directory.data = (2.seconds.ago.to_f * 1000).to_i
          directory.store

          put "/jimmy/tasks/private/projects/world-domination/start", "write a manifesto"

          object = data_bucket.get("jimmy:tasks/private/projects/world-domination:start")
          directory = directory_bucket.get("jimmy:tasks")

          directory.data.to_i.must_equal object.meta['timestamp'][0].to_i
        end
      end

      context "with binary data" do
        context "charset given in content-type header" do
          before do
            header "Content-Type", "image/jpeg; charset=binary"
            filename = File.join(File.expand_path(File.dirname(__FILE__)), "fixtures", "rockrule.jpeg")
            @image = File.open(filename, "r").read
            put "/jimmy/tasks/jaypeg.jpg", @image
          end

          it "lists the binary files" do
            get "/jimmy/tasks/"

            last_response.status.must_equal 200

            jaypeg = data_bucket.get("jimmy:tasks:jaypeg.jpg")

            content = JSON.parse(last_response.body)
            content["items"]["jaypeg.jpg"]["ETag"].must_equal jaypeg.etag.gsub(/"/, "")
            content["items"]["jaypeg.jpg"]["Content-Type"].must_equal "image/jpeg"
            content["items"]["jaypeg.jpg"]["Content-Length"].must_equal 16044
          end
        end

        context "no charset in content-type header" do
          before do
            header "Content-Type", "image/jpeg"
            filename = File.join(File.expand_path(File.dirname(__FILE__)), "fixtures", "rockrule.jpeg")
            @image = File.open(filename, "r").read
            put "/jimmy/tasks/jaypeg.jpg", @image
          end

          it "lists the binary files" do
            get "/jimmy/tasks/"

            last_response.status.must_equal 200

            jaypeg = data_bucket.get("jimmy:tasks:jaypeg.jpg")

            content = JSON.parse(last_response.body)
            content["items"]["jaypeg.jpg"]["ETag"].must_equal jaypeg.etag.gsub(/"/, "")
            content["items"]["jaypeg.jpg"]["Content-Type"].must_equal "image/jpeg"
            content["items"]["jaypeg.jpg"]["Content-Length"].must_equal 16044
          end
        end
      end
    end

    context "for a sub-directory" do
      before do
        put "/jimmy/tasks/home/laundry", "do the laundry"
      end

      it "lists the objects with timestamp" do
        get "/jimmy/tasks/home/"

        last_response.status.must_equal 200

        laundry = data_bucket.get("jimmy:tasks/home:laundry")

        content = JSON.parse(last_response.body)
        content["items"]["laundry"]["ETag"].must_equal laundry.etag.gsub(/"/, "")
      end
    end

    context "for an empty or absent directory" do
      it "returns an empty listing" do
        get "/jimmy/documents/notfound/"

        last_response.status.must_equal 404
      end
    end

    context "special characters in directory name" do
      before do
        put "/jimmy/tasks/foo~bar/task1", "some task"
      end

      it "lists the directory in the parent directory" do
        get "/jimmy/tasks/"

        last_response.status.must_equal 200

        content = JSON.parse(last_response.body)
        content["items"]["foo~bar/"].wont_be_nil
      end

      it "lists the containing objects" do
        get "/jimmy/tasks/foo~bar/"

        last_response.status.must_equal 200

        content = JSON.parse(last_response.body)
        content["items"]["task1"].wont_be_nil
      end

      it "returns the requested object" do
        get "/jimmy/tasks/foo~bar/task1"

        last_response.status.must_equal 200

        last_response.body.must_equal "some task"
      end
    end

    context "special characters in object name" do
      before do
        put "/jimmy/tasks/bla~blub", "some task"
      end

      it "lists the containing object" do
        get "/jimmy/tasks/"

        last_response.status.must_equal 200

        content = JSON.parse(last_response.body)
        content["items"]["bla~blub"].wont_be_nil
      end
    end

    context "for the root directory" do
      before do
        auth = auth_bucket.new("jimmy:123")
        auth.data = [":rw"]
        auth.store

        put "/jimmy/root-1", "Put my root down"
        put "/jimmy/root-2", "Back to the roots"
      end

      it "lists the containing objects and direct sub-directories" do
        get "/jimmy/"

        last_response.status.must_equal 200

        tasks = directory_bucket.get("jimmy:tasks")

        content = JSON.parse(last_response.body)
        content["items"]["root-1"].wont_be_nil
        content["items"]["root-2"].wont_be_nil
        content["items"]["tasks/"].wont_be_nil
        content["items"]["tasks/"]["ETag"].must_equal tasks.etag.gsub(/"/, "")
      end

      it "has an ETag header set" do
        get "/jimmy/"

        last_response.status.must_equal 200
        last_response.headers["ETag"].wont_be_nil
      end
    end

    context "for the public directory" do
      before do
        auth = auth_bucket.new("jimmy:123")
        auth.data = ["documents:r", "bookmarks:rw"]
        auth.store

        put "/jimmy/public/bookmarks/5apps", "http://5apps.com"
      end

      context "when authorized for the category" do
        it "lists the files" do
          get "/jimmy/public/bookmarks/"

          last_response.status.must_equal 200

          content = JSON.parse(last_response.body)
          content["items"]["5apps"].wont_be_nil
        end

        it "has an ETag header set" do
          get "/jimmy/public/bookmarks/"

          last_response.status.must_equal 200
          last_response.headers["ETag"].wont_be_nil
        end
      end

      context "when directly authorized for the public directory" do
        before do
          auth = auth_bucket.new("jimmy:123")
          auth.data = ["documents:r", "public/bookmarks:rw"]
          auth.store
        end

        it "lists the files" do
          get "/jimmy/public/bookmarks/"

          last_response.status.must_equal 200

          content = JSON.parse(last_response.body)
          content["items"]["5apps"].wont_be_nil
        end
      end

      context "when not authorized" do
        before do
          auth_bucket.delete("jimmy:123")
        end

        it "does not allow a directory listing of the public root" do
          get "/jimmy/public/"

          last_response.status.must_equal 401
        end

        it "does not allow a directory listing of a sub-directory" do
          get "/jimmy/public/bookmarks/"

          last_response.status.must_equal 401
        end
      end
    end
  end

  describe "directory object" do
    describe "PUT file" do
      context "no existing directory object" do
        before do
          put "/jimmy/tasks/home/trash", "take out the trash"
        end

        it "creates a new directory object" do
          object = data_bucket.get("jimmy:tasks/home:trash")
          directory = directory_bucket.get("jimmy:tasks/home")

          directory.data.wont_be_nil
          directory.data.to_i.must_equal object.meta['timestamp'][0].to_i
        end

        it "sets the correct index for the directory object" do
          object = directory_bucket.get("jimmy:tasks/home")
          object.indexes["directory_bin"].must_include "tasks"
        end

        it "creates directory objects for the parent directories" do
          object = directory_bucket.get("jimmy:tasks")
          object.indexes["directory_bin"].must_include "/"
          object.data.wont_be_nil

          object = directory_bucket.get("jimmy:")
          object.indexes["directory_bin"].must_be_empty
          object.data.wont_be_nil
        end
      end

      context "existing directory object" do
        before do
          put "/jimmy/tasks/home/trash", "collect some trash"
        end

        it "updates the timestamp of the directory" do
          put "/jimmy/tasks/home/trash", "take out the trash"

          last_response.status.must_equal 200

          object = data_bucket.get("jimmy:tasks/home:trash")
          directory = directory_bucket.get("jimmy:tasks/home")

          directory.data.to_i.must_equal object.meta['timestamp'][0].to_i
        end
      end
    end
  end

  describe "OPTIONS listing" do
    it "has CORS headers set" do
      options "/jimmy/tasks/"

      last_response.status.must_equal 200

      last_response.headers["Access-Control-Allow-Origin"].must_equal "*"
      last_response.headers["Access-Control-Allow-Methods"].must_equal "GET, PUT, DELETE"
      last_response.headers["Access-Control-Allow-Headers"].must_equal "Authorization, Content-Type, Origin, If-Match, If-None-Match"
      last_response.headers["Access-Control-Expose-Headers"].must_equal "ETag"
    end

    context "sub-directories" do
      it "has CORS headers set" do
        options "/jimmy/tasks/foo/bar/"

        last_response.status.must_equal 200

        last_response.headers["Access-Control-Allow-Origin"].must_equal "*"
        last_response.headers["Access-Control-Allow-Methods"].must_equal "GET, PUT, DELETE"
        last_response.headers["Access-Control-Allow-Headers"].must_equal "Authorization, Content-Type, Origin, If-Match, If-None-Match"
        last_response.headers["Access-Control-Expose-Headers"].must_equal "ETag"
      end
    end

    context "root directory" do
      it "has CORS headers set" do
        options "/jimmy/"

        last_response.status.must_equal 200

        last_response.headers["Access-Control-Allow-Origin"].must_equal "*"
        last_response.headers["Access-Control-Allow-Methods"].must_equal "GET, PUT, DELETE"
        last_response.headers["Access-Control-Allow-Headers"].must_equal "Authorization, Content-Type, Origin, If-Match, If-None-Match"
        last_response.headers["Access-Control-Expose-Headers"].must_equal "ETag"
      end
    end
  end

  describe "DELETE file" do
    context "last file in directory" do
      before do
        put "/jimmy/tasks/home/trash", "take out the trash"
      end

      it "deletes the directory objects for all empty parent directories" do
        delete "/jimmy/tasks/home/trash"

        last_response.status.must_equal 200

        lambda {
          directory_bucket.get("jimmy:tasks/home")
        }.must_raise Riak::HTTPFailedRequest

        lambda {
          directory_bucket.get("jimmy:tasks")
        }.must_raise Riak::HTTPFailedRequest

        lambda {
          directory_bucket.get("jimmy:")
        }.must_raise Riak::HTTPFailedRequest
      end
    end

    context "with additional files in directory" do
      before do
        put "/jimmy/tasks/home/trash", "take out the trash"
        put "/jimmy/tasks/home/laundry/washing", "wash the clothes"
      end

      it "does not delete the directory objects for the parent directories" do
        delete "/jimmy/tasks/home/trash"

        directory_bucket.get("jimmy:tasks/home").wont_be_nil
        directory_bucket.get("jimmy:tasks").wont_be_nil
        directory_bucket.get("jimmy:").wont_be_nil
      end

      it "updates the ETag headers of all parent directories" do
        get "/jimmy/tasks/home/"
        home_etag = last_response.headers["ETag"]

        get "/jimmy/tasks/"
        tasks_etag = last_response.headers["ETag"]

        get "/jimmy/"
        root_etag = last_response.headers["ETag"]

        delete "/jimmy/tasks/home/trash"

        get "/jimmy/tasks/home/"
        last_response.headers["ETag"].wont_be_nil
        last_response.headers["ETag"].wont_equal home_etag

        get "/jimmy/tasks/"
        last_response.headers["ETag"].wont_be_nil
        last_response.headers["ETag"].wont_equal tasks_etag

        get "/jimmy/"
        last_response.headers["ETag"].wont_be_nil
        last_response.headers["ETag"].wont_equal root_etag
      end

      describe "timestamps" do
        before do
          @old_timestamp = (2.seconds.ago.to_f * 1000).to_i

          ["tasks/home", "tasks", ""].each do |dir|
            directory = directory_bucket.get("jimmy:#{dir}")
            directory.data = @old_timestamp.to_s
            directory.store
          end
        end

        it "updates the timestamp for the parent directories" do
          delete "/jimmy/tasks/home/trash"

          directory_bucket.get("jimmy:tasks/home").data.to_i.must_be :>, @old_timestamp
          directory_bucket.get("jimmy:tasks").data.to_i.must_be :>, @old_timestamp
          directory_bucket.get("jimmy:").data.to_i.must_be :>, @old_timestamp
        end
      end
    end
  end

end
