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
    end

    context "authorized" do
      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"
      end

      it "creates the metadata object in redis" do
        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          last_modified: "Fri, 04 Mar 2016 12:20:18 GMT"
        })

        RestClient.stub :put, put_stub do
          put "/phil/food/aguacate", "si"
        end

        metadata = redis.hgetall "rs:m:phil:food/aguacate"
        metadata["s"].must_equal "2"
        metadata["t"].must_equal "text/plain; charset=utf-8"
        metadata["e"].must_equal "bla"
        metadata["m"].length.must_equal 13
      end

      it "creates the directory objects metadata in redis" do
        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          last_modified: "Fri, 04 Mar 2016 12:20:18 GMT"
        })
        get_stub = OpenStruct.new(body: "rootbody")

        RestClient.stub :put, put_stub do
          RestClient.stub :get, get_stub do
            RemoteStorage::Swift.stub_any_instance :etag_for, "newetag" do
              put "/phil/food/aguacate", "si"
              put "/phil/food/camaron", "yummi"
            end
          end
        end

        metadata = redis.hgetall "rs:m:phil:/"
        metadata["e"].must_equal "newetag"
        metadata["m"].length.must_equal 13

        metadata = redis.hgetall "rs:m:phil:food/"
        metadata["e"].must_equal "newetag"
        metadata["m"].length.must_equal 13

        food_items = redis.smembers "rs:m:phil:food/:items"
        food_items.each do |food_item|
          ["camaron", "aguacate"].must_include food_item
        end

        root_items = redis.smembers "rs:m:phil:/:items"
        root_items.must_equal ["food/"]
      end

      describe "objects in root dir" do
        before do
          put_stub = OpenStruct.new(headers: {
            etag: "bla",
            last_modified: "Fri, 04 Mar 2016 12:20:18 GMT"
          })

          RestClient.stub :put, put_stub do
            put "/phil/bamboo.txt", "shir kan"
          end
        end

        it "are listed in the directory listing with all metadata" do
          get "phil/"

          last_response.status.must_equal 200
          last_response.content_type.must_equal "application/json"

          content = JSON.parse(last_response.body)
          content["items"]["bamboo.txt"].wont_be_nil
          content["items"]["bamboo.txt"]["ETag"].must_equal "bla"
          content["items"]["bamboo.txt"]["Content-Type"].must_equal "text/plain; charset=utf-8"
          content["items"]["bamboo.txt"]["Content-Length"].must_equal 8
        end
      end

      describe "name collision checks" do
        it "is successful when there is no name collision" do
          put_stub = OpenStruct.new(headers: {
            etag: "bla",
            last_modified: "Fri, 04 Mar 2016 12:20:18 GMT"
          })
          get_stub = OpenStruct.new(body: "rootbody")

          RestClient.stub :put, put_stub do
            RestClient.stub :get, get_stub do
              RemoteStorage::Swift.stub_any_instance :etag_for, "rootetag" do
                put "/phil/food/aguacate", "si"
              end
            end
          end

          last_response.status.must_equal 200

          metadata = redis.hgetall "rs:m:phil:food/aguacate"
          metadata["s"].must_equal "2"
        end

        it "conflicts when there is a directory with same name as document" do
          put_stub = OpenStruct.new(headers: {
            etag: "bla",
            last_modified: "Fri, 04 Mar 2016 12:20:18 GMT"
          })

          RestClient.stub :put, put_stub do
            put "/phil/food/aguacate", "si"
            put "/phil/food", "wontwork"
          end

          last_response.status.must_equal 409

          metadata = redis.hgetall "rs:m:phil:food"
          metadata.must_be_empty
        end

        it "conflicts when there is a document with same name as directory" do
          put_stub = OpenStruct.new(headers: {
            etag: "bla",
            last_modified: "Fri, 04 Mar 2016 12:20:18 GMT"
          })

          RestClient.stub :put, put_stub do
            put "/phil/food/aguacate", "si"
            put "/phil/food/aguacate/empanado", "wontwork"
          end

          last_response.status.must_equal 409

          metadata = redis.hgetall "rs:m:phil:food/aguacate/empanado"
          metadata.must_be_empty
        end

        it "returns 400 when a Content-Range header is sent" do
          header "Content-Range", "bytes 0-3/3"

          put "/phil/food/aguacate", "si"

          last_response.status.must_equal 400
        end
      end
    end
  end

  describe "DELETE requests" do

    before do
      purge_redis
    end

    context "authorized" do
      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          last_modified: "Fri, 04 Mar 2016 12:20:18 GMT"
        })

        RestClient.stub :put, put_stub do
          put "/phil/food/aguacate", "si"
          put "/phil/food/camaron", "yummi"
        end
      end

      it "deletes the metadata object in redis" do
        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          last_modified: "Fri, 04 Mar 2016 12:20:18 GMT"
        })
        get_stub = OpenStruct.new(body: "rootbody")

        RestClient.stub :put, put_stub do
          RestClient.stub :delete, "" do
            RestClient.stub :get, get_stub do
              RemoteStorage::Swift.stub_any_instance :etag_for, "rootetag" do
                delete "/phil/food/aguacate"
              end
            end
          end
        end

        metadata = redis.hgetall "rs:m:phil:food/aguacate"
        metadata.must_be_empty
      end

      it "deletes the directory objects metadata in redis" do
        old_metadata = redis.hgetall "rs:m:phil:food/"

        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          last_modified: "Fri, 04 Mar 2016 12:20:18 GMT"
        })
        get_stub = OpenStruct.new(body: "rootbody")

        RestClient.stub :put, put_stub do
          RestClient.stub :delete, "" do
            RestClient.stub :get, get_stub do
              RemoteStorage::Swift.stub_any_instance :etag_for, "newetag" do
                delete "/phil/food/aguacate"
              end
            end
          end
        end

        metadata = redis.hgetall "rs:m:phil:food/"
        metadata["e"].must_equal "newetag"
        metadata["m"].length.must_equal 13
        metadata["m"].wont_equal old_metadata["m"]

        food_items = redis.smembers "rs:m:phil:food/:items"
        food_items.must_equal ["camaron"]

        root_items = redis.smembers "rs:m:phil:/:items"
        root_items.must_equal ["food/"]
      end

      it "deletes the parent directory objects metadata when deleting all items" do
        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          last_modified: "Fri, 04 Mar 2016 12:20:18 GMT"
        })
        get_stub = OpenStruct.new(body: "rootbody")

        RestClient.stub :put, put_stub do
          RestClient.stub :delete, "" do
            RestClient.stub :get, get_stub do
              RemoteStorage::Swift.stub_any_instance :etag_for, "rootetag" do
                delete "/phil/food/aguacate"
                delete "/phil/food/camaron"
              end
            end
          end
        end

        metadata = redis.hgetall "rs:m:phil:food/"
        metadata.must_be_empty

        food_items = redis.smembers "rs:m:phil:food/:items"
        food_items.must_be_empty

        root_items = redis.smembers "rs:m:phil:/:items"
        root_items.must_be_empty
      end
    end
  end

  describe "GET requests" do

    before do
      purge_redis
    end

    context "authorized" do

      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          last_modified: "Fri, 04 Mar 2016 12:20:18 GMT"
        })

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
          last_response.headers["ETag"].must_equal "\"f9f85fbf5aa1fa378fd79ac8aa0a457d\""
        end

        it "responds with 304 when IF_NONE_MATCH header contains the ETag" do
          header "If-None-Match", "\"f9f85fbf5aa1fa378fd79ac8aa0a457d\""
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
          content["items"]["desunyos/"]["ETag"].must_equal "926233ce4a147a5b679e0ddf665517dd"
        end

        it "contains all items in the root directory" do
          get "phil/"

          last_response.status.must_equal 200
          last_response.content_type.must_equal "application/json"

          content = JSON.parse(last_response.body)
          content["items"]["food/"].wont_be_nil
          content["items"]["food/"]["ETag"].must_equal "f9f85fbf5aa1fa378fd79ac8aa0a457d"
        end

      end
    end

  end
end

