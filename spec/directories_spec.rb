require_relative "spec_helper"

describe "Directories" do
  include Rack::Test::Methods
  include RemoteStorage::Riak

  before do
    purge_all_buckets

    auth = auth_bucket.new("jimmy:123")
    auth.data = [":r", "documents:r", "tasks:rw"]
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
          old_timestamp = (Time.now.to_i - 2).to_s
          tasks_object = directory_bucket.get("jimmy:tasks")
          tasks_object.data = old_timestamp
          tasks_object.store

          put "/jimmy/tasks/private/projects/world-domination/start", "write a manifesto"

          tasks_object.reload.data.must_equal old_timestamp
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

    context "for an empty or absent directory" do
      it "returns an empty listing" do
        get "/jimmy/documents/notfound/"

        last_response.status.must_equal 200
        last_response.body.must_equal "{}"
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

        content = JSON.parse(last_response.body)
        content.must_include "root-1"
        content.must_include "root-2"
        content.must_include "tasks/"
        content["tasks/"].to_s.must_match /\d+/
        content["tasks/"].to_s.length.must_be :>=, 10
      end
    end
  end

  describe "directory object" do
    describe "PUT file" do
      context "no existing directory object" do
        it "creates a new directory object" do
          put "/jimmy/tasks/home/trash", "take out the trash"

          object = data_bucket.get("jimmy:tasks/home:trash")
          directory = directory_bucket.get("jimmy:tasks/home")

          directory.data.wont_be_nil
          directory.data.to_i.must_equal object.last_modified.to_i
        end

        it "sets the correct index for the directory object" do
          put "/jimmy/tasks/home/trash", "take out the trash"

          object = directory_bucket.get("jimmy:tasks/home")
          object.indexes["directory_bin"].must_include "tasks"
        end

        it "creates directory objects for the parent directories" do
          put "/jimmy/tasks/home/trash", "take out the trash"

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
          directory = directory_bucket.new("jimmy:tasks/home")
          directory.content_type = "text/plain"
          directory.data = 2.seconds.ago.to_i.to_s
          directory.store
        end

        it "updates the timestamp of the directory" do
          put "/jimmy/tasks/home/trash", "take out the trash"

          last_response.status.must_equal 200

          object = data_bucket.get("jimmy:tasks/home:trash")
          directory = directory_bucket.get("jimmy:tasks/home")

          directory.data.to_i.must_equal object.last_modified.to_i
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

    context "root directory" do
      it "has CORS headers set" do
        options "/jimmy/"

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
