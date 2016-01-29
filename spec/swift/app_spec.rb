require_relative "../spec_helper"

describe "App" do
  include Rack::Test::Methods

  def app
    LiquorCabinet
  end

  it "returns 404 on non-existing routes" do
    get "/virginmargarita"
    last_response.status.must_equal 404
  end

  describe "PUT requests" do

    before do
      purge_redis
      redis.set "rs_config:dir_backend:phil", "new"
    end

    context "authorized" do
      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"
      end

      it "creates the metadata object in redis" do
        put_stub = OpenStruct.new(headers: {etag: "bla"})
        RestClient.stub :put, put_stub do
          put "/phil/food/aguacate", "si"
        end

        metadata = redis.hgetall "rs_meta:phil:food/aguacate"
        metadata["size"].must_equal "2"
        metadata["type"].must_equal "text/plain; charset=utf-8"
        metadata["etag"].must_equal "bla"
        metadata["modified"].must_equal nil
      end

      it "creates the directory objects metadata in redis" do
        put_stub = OpenStruct.new(headers: {etag: "bla"})
        RestClient.stub :put, put_stub do
          put "/phil/food/aguacate", "si"
          put "/phil/food/camaron", "yummi"
        end

        metadata = redis.hgetall "rs_meta:phil:/"
        metadata["etag"].must_equal "bla"
        metadata["modified"].length.must_equal 13

        metadata = redis.hgetall "rs_meta:phil:food/"
        metadata["etag"].must_equal "bla"
        metadata["modified"].length.must_equal 13

        food_items = redis.smembers "rs_meta:phil:food/:items"
        food_items.each do |food_item|
          ["camaron", "aguacate"].must_include food_item
        end

        root_items = redis.smembers "rs_meta:phil:/:items"
        root_items.must_equal ["food/"]
      end

      describe "name collision checks" do
        it "is successful when there is no name collision" do
          put_stub = OpenStruct.new(headers: {etag: "bla"})
          RestClient.stub :put, put_stub do
            put "/phil/food/aguacate", "si"
          end

          last_response.status.must_equal 200

          metadata = redis.hgetall "rs_meta:phil:food/aguacate"
          metadata["size"].must_equal "2"
        end

        it "conflicts when there is a directory with same name as document" do
          put_stub = OpenStruct.new(headers: {etag: "bla"})
          RestClient.stub :put, put_stub do
            put "/phil/food/aguacate", "si"
            put "/phil/food", "wontwork"
          end

          last_response.status.must_equal 409

          metadata = redis.hgetall "rs_meta:phil:food"
          metadata.must_be_empty
        end

        it "conflicts when there is a document with same name as directory" do
          put_stub = OpenStruct.new(headers: {etag: "bla"})
          RestClient.stub :put, put_stub do
            put "/phil/food/aguacate", "si"
            put "/phil/food/aguacate/empanado", "wontwork"
          end

          last_response.status.must_equal 409

          metadata = redis.hgetall "rs_meta:phil:food/aguacate/empanado"
          metadata.must_be_empty
        end
      end

      describe "directory backend configuration" do
        context "locked new backed" do
          before do
            redis.set "rs_config:dir_backend:phil", "new-locked"
          end

          it "responds with 503" do
            put "/phil/food/aguacate", "si"

            last_response.status.must_equal 503

            metadata = redis.hgetall "rs_meta:phil:food/aguacate"
            metadata.must_be_empty
          end
        end

        context "locked legacy backend" do
          before do
            redis.set "rs_config:dir_backend:phil", "legacy-locked"
          end

          it "responds with 503" do
            put "/phil/food/aguacate", "si"

            last_response.status.must_equal 503

            metadata = redis.hgetall "rs_meta:phil:food/aguacate"
            metadata.must_be_empty
          end
        end
      end
    end
  end

  describe "DELETE requests" do

    before do
      purge_redis
      redis.set "rs_config:dir_backend:phil", "new"
    end

    context "authorized" do
      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put_stub = OpenStruct.new(headers: {etag: "bla"})
        RestClient.stub :put, put_stub do
          put "/phil/food/aguacate", "si"
          put "/phil/food/camaron", "yummi"
        end
      end

      it "deletes the metadata object in redis" do
        put_stub = OpenStruct.new(headers: {etag: "bla"})
        RemoteStorage::Swift.stub_any_instance :dir_empty?, false do
          RestClient.stub :put, put_stub do
            RestClient.stub :delete, "" do
              delete "/phil/food/aguacate"
            end
          end
        end

        metadata = redis.hgetall "rs_meta:phil:food/aguacate"
        metadata.must_be_empty
      end

      it "deletes the directory objects metadata in redis" do
        old_metadata = redis.hgetall "rs_meta:phil:food/"

        put_stub = OpenStruct.new(headers: {etag: "newetag"})
        RemoteStorage::Swift.stub_any_instance :dir_empty?, false do
          RestClient.stub :put, put_stub do
            RestClient.stub :delete, "" do
              delete "/phil/food/aguacate"
            end
          end
        end

        metadata = redis.hgetall "rs_meta:phil:food/"
        metadata["etag"].must_equal "newetag"
        metadata["modified"].length.must_equal 13
        metadata["modified"].wont_equal old_metadata["modified"]

        food_items = redis.smembers "rs_meta:phil:food/:items"
        food_items.must_equal ["camaron"]

        root_items = redis.smembers "rs_meta:phil:/:items"
        root_items.must_equal ["food/"]
      end

      it "deletes the parent directory objects metadata when deleting all items" do
        put_stub = OpenStruct.new(headers: {etag: "bla"})
        RemoteStorage::Swift.stub_any_instance :dir_empty?, false do
          RestClient.stub :put, put_stub do
            RestClient.stub :delete, "" do
              delete "/phil/food/aguacate"
            end
          end
        end

        RemoteStorage::Swift.stub_any_instance :dir_empty?, true do
          RestClient.stub :delete, "" do
            delete "/phil/food/camaron"
          end
        end

        metadata = redis.hgetall "rs_meta:phil:food/"
        metadata.must_be_empty

        food_items = redis.smembers "rs_meta:phil:food/:items"
        food_items.must_be_empty

        root_items = redis.smembers "rs_meta:phil:/:items"
        root_items.must_be_empty
      end
    end
  end

  describe "GET requests" do

    before do
      purge_redis
      redis.set "rs_config:dir_backend:phil", "new"
    end

    context "authorized" do

      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put_stub = OpenStruct.new(headers: {etag: "bla"})
        RestClient.stub :put, put_stub do
          put "/phil/food/aguacate", "si"
          put "/phil/food/camaron", "yummi"
          put "/phil/food/desunyos/bolon", "wow"
        end
      end

      describe "directory listings" do

        it "has an ETag in the header" do
          get "/phil/food/"

          last_response.status.must_equal 200
          last_response.headers["ETag"].must_equal "\"bla\""
        end

        it "responds with 304 when IF_NONE_MATCH header contains the ETag" do
          header "If-None-Match", "bla"
          get "/phil/food/"

          last_response.status.must_equal 304
        end

        it "contains all items in the directory" do
          get "/phil/food/"

          last_response.status.must_equal 200
          last_response.content_type.must_equal "application/json"

          content = JSON.parse(last_response.body)
          content["@context"].must_equal "http://remotestorage.io/spec/folder-description"
          content["items"]["aguacate"].wont_be_nil
          content["items"]["aguacate"]["Content-Type"].must_equal "text/plain; charset=utf-8"
          content["items"]["aguacate"]["Content-Length"].must_equal 2
          content["items"]["aguacate"]["ETag"].must_equal "bla"
          content["items"]["camaron"].wont_be_nil
          content["items"]["camaron"]["Content-Type"].must_equal "text/plain; charset=utf-8"
          content["items"]["camaron"]["Content-Length"].must_equal 5
          content["items"]["camaron"]["ETag"].must_equal "bla"
          content["items"]["desunyos/"].wont_be_nil
          content["items"]["desunyos/"]["ETag"].must_equal "bla"
        end

        it "contains all items in the root directory" do
          get "phil/"

          last_response.status.must_equal 200
          last_response.content_type.must_equal "application/json"

          content = JSON.parse(last_response.body)
          content["items"]["food/"].wont_be_nil
          content["items"]["food/"]["ETag"].must_equal "bla"
        end

      end
    end

    context "with legacy directory backend" do

      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put_stub = OpenStruct.new(headers: {etag: "bla"})
        RestClient.stub :put, put_stub do
          put "/phil/food/aguacate", "si"
          put "/phil/food/camaron", "yummi"
        end

        redis.set "rs_config:dir_backend:phil", "legacy"
      end

      it "serves directory listing from Swift backend" do
        RemoteStorage::Swift.stub_any_instance :get_directory_listing_from_swift, "directory listing" do
          get "/phil/food/"
        end

        last_response.status.must_equal 200
        last_response.body.must_equal "directory listing"
      end

    end

  end
end

