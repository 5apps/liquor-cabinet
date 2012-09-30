require_relative "spec_helper"

describe "Directories" do
  include Rack::Test::Methods
  include RemoteStorage::Riak

  before do
    purge_all_buckets

    auth = auth_bucket.new("jimmy:123")
    auth.data = ["documents:r", "tasks:rw"]
    auth.store

    header "Authorization", "Bearer 123"
  end

  describe "GET listing" do

    before do
      put "/jimmy/tasks/foo", "do the laundry"
      put "/jimmy/tasks/bar", "do the laundry"
    end

    it "lists the objects with a timestamp of the last modification" do
      get "/jimmy/tasks/"

      last_response.status.must_equal 200
      last_response.content_type.must_equal "application/json"

      content = JSON.parse(last_response.body)
      content.must_include "bar"
      content.must_include "foo"
      content["foo"].to_s.must_match /\d+/
      content["foo"].to_s.length.must_be :>=, 10
    end

    it "has a Last-Modifier header set" do
      get "/jimmy/tasks/"

      last_response.headers["Last-Modified"].wont_be_nil
    end

    it "has CORS headers set" do
      get "/jimmy/tasks/"

      last_response.headers["Access-Control-Allow-Origin"].must_equal "*"
      last_response.headers["Access-Control-Allow-Methods"].must_equal "GET, PUT, DELETE"
      last_response.headers["Access-Control-Allow-Headers"].must_equal "Authorization, Content-Type, Origin"
    end

    context "with sub-directories" do
      before do
        put "/jimmy/tasks/home/laundry", "do the laundry"
      end

      it "lists the containing objects as well as the direct sub-directories" do
        get "/jimmy/tasks/"

        last_response.status.must_equal 200

        content = JSON.parse(last_response.body)
        content.must_include "foo"
        content.must_include "bar"
        content.must_include "home/"
        content["home/"].to_s.must_match /\d+/
        content["home/"].to_s.length.must_be :>=, 10
      end

      context "sub-directories without objects" do
        it "lists the direct sub-directories" do
          put "/jimmy/tasks/private/projects/world-domination/start", "write a manifesto"
          get "/jimmy/tasks/private/"

          last_response.status.must_equal 200

          content = JSON.parse(last_response.body)
          content.must_include "projects/"
          content["projects/"].to_s.must_match /\d+/
          content["projects/"].to_s.length.must_be :>=, 10
        end

        it "does not update existing directory objects" do
          tasks_timestamp = directory_bucket.get("jimmy:tasks").last_modified
          wait_a_second
          put "/jimmy/tasks/private/projects/world-domination/start", "write a manifesto"

          tasks_object = directory_bucket.get("jimmy:tasks")
          tasks_object.last_modified.must_equal tasks_timestamp
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

        content = JSON.parse(last_response.body)
        content.must_include "laundry"
        content["laundry"].to_s.must_match /\d+/
        content["laundry"].to_s.length.must_be :>=, 10
      end
    end

    describe "for an empty or absent directory" do
      it "returns an empty listing" do
        get "/jimmy/documents/notfound/"

        last_response.status.must_equal 200
        last_response.body.must_equal "{}"
      end
    end
  end

  describe "directory object" do
    describe "PUT file" do
      context "no existing directory object" do
        it "creates a new directory object" do
          put "/jimmy/tasks/home/trash", "take out the trash"

          object = directory_bucket.get("jimmy:tasks/home")
          object.last_modified.wont_be_nil
        end

        it "sets the correct index for the directory object" do
          put "/jimmy/tasks/home/trash", "take out the trash"

          object = directory_bucket.get("jimmy:tasks/home")
          object.indexes["directory_bin"].must_include "tasks"
        end
      end

      context "existing directory object" do
        before do
          @directory = directory_bucket.new("jimmy:tasks/home")
          @directory.content_type = "text/plain"
          @directory.raw_data = ""
          @directory.store
          @old_timestamp = @directory.reload.last_modified
        end

        it "updates the timestamp of the directory" do
          wait_a_second
          put "/jimmy/tasks/home/trash", "take out the trash"

          @directory.reload
          @directory.last_modified.must_be :>, @old_timestamp
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
      last_response.headers["Access-Control-Allow-Headers"].must_equal "Authorization, Content-Type, Origin"
    end

    context "sub-directories" do
      it "has CORS headers set" do
        options "/jimmy/tasks/foo/bar/"

        last_response.status.must_equal 200

        last_response.headers["Access-Control-Allow-Origin"].must_equal "*"
        last_response.headers["Access-Control-Allow-Methods"].must_equal "GET, PUT, DELETE"
        last_response.headers["Access-Control-Allow-Headers"].must_equal "Authorization, Content-Type, Origin"
      end
    end
  end

  describe "DELETE file" do
    context "last file in directory" do
      before do
        directory_bucket.delete("jimmy:tasks")
        put "/jimmy/tasks/trash", "take out the trash"
      end

      it "deletes the directory object" do
        delete "/jimmy/tasks/trash"

        last_response.status.must_equal 204

        lambda {
          directory_bucket.get("jimmy:tasks")
        }.must_raise Riak::HTTPFailedRequest
      end
    end
  end

end
