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
        redis.sadd "authorizations:ilpt-phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"
      end

      it "creates the metadata object in redis" do
        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          date: "Fri, 04 Mar 2016 12:20:18 GMT"
        })

        RestClient.stub :put, put_stub do
          put "/ilpt-phil/food/aguacate", "si"
        end

        metadata = redis.hgetall "rs:m:ilpt-phil:food/aguacate"
        metadata["s"].must_equal "2"
        metadata["t"].must_equal "text/plain; charset=utf-8"
        metadata["e"].must_equal "bla"
        metadata["m"].length.must_equal 13
      end

      it "creates the directory objects metadata in redis" do
        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          date: "Fri, 04 Mar 2016 12:20:18 GMT"
        })
        get_stub = OpenStruct.new(body: JSON.generate("_id" => "ilpt-phil%2Ffood%2Faguacate",
                                                       "rev" => "123-12345667"))

        RestClient.stub :put, put_stub do
          RestClient.stub :get, get_stub do
            RemoteStorage::CouchDB.stub_any_instance :etag_for, "newetag" do
              put "/ilpt-phil/food/aguacate", "si"
              put "/ilpt-phil/food/camaron", "yummi"
            end
          end
        end

        metadata = redis.hgetall "rs:m:ilpt-phil:/"
        metadata["e"].must_equal "newetag"
        metadata["m"].length.must_equal 13

        food_items = redis.smembers "rs:m:ilpt-phil:food/:items"
        food_items.each do |food_item|
          ["camaron", "aguacate"].must_include food_item
        end

        root_items = redis.smembers "rs:m:ilpt-phil:/:items"
        root_items.must_equal ["food/"]
      end

      context "response code" do
        before do
          @put_stub = OpenStruct.new(headers: {
            etag: "bla",
            date: "Fri, 04 Mar 2016 12:20:18 GMT"
          })
        end

        it "is 201 for newly created objects" do
          RestClient.stub :put, @put_stub do
            put "/ilpt-phil/food/aguacate", "muy deliciosa"
          end

          last_response.status.must_equal 201
        end

        it "is 200 for updated objects" do
          RestClient.stub :put, @put_stub do
            put "/ilpt-phil/food/aguacate", "deliciosa"
            put "/ilpt-phil/food/aguacate", "muy deliciosa"
          end

          last_response.status.must_equal 200
        end
      end

      context "logging usage size" do
        before do
          @put_stub = OpenStruct.new(headers: {
            etag: "bla",
            date: "Fri, 04 Mar 2016 12:20:18 GMT"
          })
        end

        it "logs the complete size when creating new objects" do
          RestClient.stub :put, @put_stub do
            put "/ilpt-phil/food/aguacate", "1234567890"
          end

          size_log = redis.get "rs:s:ilpt-phil"
          size_log.must_equal "10"
        end

        it "logs the size difference when updating existing objects" do
          RestClient.stub :put, @put_stub do
            put "/ilpt-phil/food/camaron",  "1234567890"
            put "/ilpt-phil/food/aguacate", "1234567890"
            put "/ilpt-phil/food/aguacate", "123"
          end

          size_log = redis.get "rs:s:ilpt-phil"
          size_log.must_equal "13"
        end
      end

      describe "objects in root dir" do
        before do
          put_stub = OpenStruct.new(headers: {
            etag: "bla",
            date: "Fri, 04 Mar 2016 12:20:18 GMT"
          })

          RestClient.stub :put, put_stub do
            put "/ilpt-phil/bamboo.txt", "shir kan"
          end
        end

        it "are listed in the directory listing with all metadata" do
          get "ilpt-phil/"

          last_response.status.must_equal 200
          last_response.content_type.must_equal "application/ld+json"

          content = JSON.parse(last_response.body)
          content["items"]["bamboo.txt"].wont_be_nil
          content["items"]["bamboo.txt"]["ETag"].must_equal "bla"
          content["items"]["bamboo.txt"]["Content-Type"].must_equal "text/plain; charset=utf-8"
          content["items"]["bamboo.txt"]["Content-Length"].must_equal 8
        end
      end

      describe "name collision checks" do
        it "is successful when there is no name collision" do
          put "/ilpt-phil/food/aguacate", "si"

          last_response.status.must_equal 201

          metadata = redis.hgetall "rs:m:ilpt-phil:food/aguacate"
          metadata["s"].must_equal "2"
        end

        it "conflicts when there is a directory with same name as document" do
          put_stub = OpenStruct.new(headers: {
            etag: "bla",
            date: "Fri, 04 Mar 2016 12:20:18 GMT"
          })

          RestClient.stub :put, put_stub do
            put "/ilpt-phil/food/aguacate", "si"
            put "/ilpt-phil/food", "wontwork"
          end

          last_response.status.must_equal 409
          last_response.body.must_equal "Conflict"

          metadata = redis.hgetall "rs:m:ilpt-phil:food"
          metadata.must_be_empty
        end

        it "conflicts when there is a document with same name as directory" do
          put_stub = OpenStruct.new(headers: {
            etag: "bla",
            date: "Fri, 04 Mar 2016 12:20:18 GMT"
          })

          RestClient.stub :put, put_stub do
            put "/ilpt-phil/food/aguacate", "si"
            put "/ilpt-phil/food/aguacate/empanado", "wontwork"
          end

          last_response.status.must_equal 409

          metadata = redis.hgetall "rs:m:ilpt-phil:food/aguacate/empanado"
          metadata.must_be_empty
        end

        it "returns 400 when a Content-Range header is sent" do
          header "Content-Range", "bytes 0-3/3"

          put "/ilpt-phil/food/aguacate", "si"

          last_response.status.must_equal 400
        end
      end

      describe "If-Match header" do
        before do
          put_stub = OpenStruct.new(headers: {
            etag: "oldetag",
            date: "Fri, 04 Mar 2016 12:20:18 GMT"
          })

          RestClient.stub :put, put_stub do
            put "/ilpt-phil/food/aguacate", "si"
          end
        end

        it "allows the request if the header matches the current ETag" do
          header "If-Match", "\"oldetag\""

          put_stub = OpenStruct.new(headers: {
            etag: "newetag",
            date: "Fri, 04 Mar 2016 12:20:18 GMT"
          })

          RestClient.stub :put, put_stub do
            put "/ilpt-phil/food/aguacate", "aye"
          end

          last_response.status.must_equal 200
          last_response.headers["Etag"].must_equal "\"newetag\""
        end

        it "fails the request if the header does not match the current ETag" do
          header "If-Match", "someotheretag"

          put "/ilpt-phil/food/aguacate", "aye"

          last_response.status.must_equal 412
          last_response.body.must_equal "Precondition Failed"
        end
      end

      describe "If-None-Match header set to '*'" do
        it "succeeds when the document doesn't exist yet" do
          put_stub = OpenStruct.new(headers: {
            etag: "someetag",
            date: "Fri, 04 Mar 2016 12:20:18 GMT"
          })

          header "If-None-Match", "*"

          RestClient.stub :put, put_stub do
            put "/ilpt-phil/food/aguacate", "si"
          end

          last_response.status.must_equal 201
        end

        it "fails the request if the document already exsits" do
          put_stub = OpenStruct.new(headers: {
            etag: "someetag",
            date: "Fri, 04 Mar 2016 12:20:18 GMT"
          })

          RestClient.stub :put, put_stub do
            put "/ilpt-phil/food/aguacate", "si"
          end

          header "If-None-Match", "*"
          RestClient.stub :put, put_stub do
            put "/ilpt-phil/food/aguacate", "si"
          end

          last_response.status.must_equal 412
          last_response.body.must_equal "Precondition Failed"
        end
      end
    end

  end

  describe "DELETE requests" do

    before do
      purge_redis
    end

    context "not authorized" do
      describe "with no token" do
        it "says it's not authorized" do
          delete "/ilpt-phil/food/aguacate"

          last_response.status.must_equal 401
          last_response.body.must_equal "Unauthorized"
        end
      end

      describe "with empty token" do
        it "says it's not authorized" do
          header "Authorization", "Bearer "
          delete "/ilpt-phil/food/aguacate"

          last_response.status.must_equal 401
          last_response.body.must_equal "Unauthorized"
        end
      end

      describe "with wrong token" do
        it "says it's not authorized" do
          header "Authorization", "Bearer wrongtoken"
          delete "/ilpt-phil/food/aguacate"

          last_response.status.must_equal 401
          last_response.body.must_equal "Unauthorized"
        end
      end

    end

    context "authorized" do
      before do
        redis.sadd "authorizations:ilpt-phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          date: "Fri, 04 Mar 2016 12:20:18 GMT"
        })

        RestClient.stub :put, put_stub do
          put "/ilpt-phil/food/aguacate", "si"
          put "/ilpt-phil/food/camaron", "yummi"
          put "/ilpt-phil/food/desayunos/bolon", "wow"
        end
      end

      it "decreases the size log by size of deleted object" do
        RestClient.stub :delete, "" do
          RemoteStorage::CouchDB.stub_any_instance :etag_for, "rootetag" do
            delete "/ilpt-phil/food/aguacate"
          end
        end

        size_log = redis.get "rs:s:ilpt-phil"
        size_log.must_equal "8"
      end

      it "deletes the metadata object in redis" do
        RestClient.stub :delete, "" do
          RemoteStorage::CouchDB.stub_any_instance :etag_for, "rootetag" do
            delete "/ilpt-phil/food/aguacate"
          end
        end

        metadata = redis.hgetall "rs:m:ilpt-phil:food/aguacate"
        metadata.must_be_empty
      end

      it "deletes the directory objects metadata in redis" do
        old_metadata = redis.hgetall "rs:m:ilpt-phil:food/"

        RestClient.stub :delete, "" do
          RemoteStorage::CouchDB.stub_any_instance :etag_for, "newetag" do
            delete "/ilpt-phil/food/aguacate"
          end
        end

        metadata = redis.hgetall "rs:m:ilpt-phil:food/"
        metadata["e"].must_equal "newetag"
        metadata["m"].length.must_equal 13
        metadata["m"].wont_equal old_metadata["m"]

        food_items = redis.smembers "rs:m:ilpt-phil:food/:items"
        food_items.sort.must_equal ["camaron", "desayunos/"]

        root_items = redis.smembers "rs:m:ilpt-phil:/:items"
        root_items.must_equal ["food/"]
      end

      it "deletes the parent directory objects metadata when deleting all items" do
        RestClient.stub :delete, "" do
          RemoteStorage::CouchDB.stub_any_instance :etag_for, "rootetag" do
            delete "/ilpt-phil/food/aguacate"
            delete "/ilpt-phil/food/camaron"
            delete "/ilpt-phil/food/desayunos/bolon"
          end
        end

        redis.smembers("rs:m:ilpt-phil:food/desayunos:items").must_be_empty
        redis.hgetall("rs:m:ilpt-phil:food/desayunos/").must_be_empty

        redis.smembers("rs:m:ilpt-phil:food/:items").must_be_empty
        redis.hgetall("rs:m:ilpt-phil:food/").must_be_empty

        redis.smembers("rs:m:ilpt-phil:/:items").must_be_empty
      end

      it "responds with the ETag of the deleted item in the header" do
        RestClient.stub :delete, "" do
          delete "/ilpt-phil/food/aguacate"
        end

        last_response.headers["ETag"].must_equal "\"bla\""
      end

      context "when item doesn't exist" do
        before do
          purge_redis

          put_stub = OpenStruct.new(headers: {
            etag: "bla",
            date: "Fri, 04 Mar 2016 12:20:18 GMT"
          })

          RestClient.stub :put, put_stub do
            put "/ilpt-phil/food/steak", "si"
          end

          raises_exception = ->(url, headers) { raise RestClient::ResourceNotFound.new }
          RestClient.stub :delete, raises_exception do
            delete "/ilpt-phil/food/steak"
          end
        end

        it "returns a 404" do
          last_response.status.must_equal 404
          last_response.body.must_equal "Not Found"
        end

        it "deletes any metadata that might still exist" do
          raises_exception = ->(url, headers) { raise RestClient::ResourceNotFound.new }
          RestClient.stub :delete, raises_exception do
            delete "/ilpt-phil/food/steak"
          end

          metadata = redis.hgetall "rs:m:ilpt-phil:food/steak"
          metadata.must_be_empty

          redis.smembers("rs:m:ilpt-phil:food/:items").must_be_empty
          redis.hgetall("rs:m:ilpt-phil:food/").must_be_empty

          redis.smembers("rs:m:ilpt-phil:/:items").must_be_empty
        end
      end

      describe "If-Match header" do
        it "succeeds when the header matches the current ETag" do
          header "If-Match", "\"bla\""

          RestClient.stub :delete, "" do
            delete "/ilpt-phil/food/aguacate"
          end

          last_response.status.must_equal 200
        end

        it "fails the request if it does not match the current ETag" do
          header "If-Match", "someotheretag"

          delete "/ilpt-phil/food/aguacate"

          last_response.status.must_equal 412
          last_response.body.must_equal "Precondition Failed"
        end
      end
    end
  end

  describe "GET requests" do

    before do
      purge_redis
    end

    context "not authorized" do

      describe "without token" do
        it "says it's not authorized" do
          get "/ilpt-phil/food/"

          last_response.status.must_equal 401
          last_response.body.must_equal "Unauthorized"
        end
      end

      describe "with wrong token" do
        it "says it's not authorized" do
          header "Authorization", "Bearer wrongtoken"
          get "/ilpt-phil/food/"

          last_response.status.must_equal 401
          last_response.body.must_equal "Unauthorized"
        end
      end

    end

    context "authorized" do

      before do
        redis.sadd "authorizations:ilpt-phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          date: "Fri, 04 Mar 2016 12:20:18 GMT"
        })

        RestClient.stub :put, put_stub do
          put "/ilpt-phil/food/aguacate", "si"
          put "/ilpt-phil/food/camaron", "yummi"
          put "/ilpt-phil/food/desayunos/bolon", "wow"
        end

        base_url = app.settings.couchdb['uri']
        res = RestClient.get("#{base_url}/ilpt-phil%2Ffood%2Faguacate")
        @aguacate_etag = res.headers[:etag]
      end

      describe "documents" do

        it "returns the required response headers" do
          get "/ilpt-phil/food/aguacate"

          last_response.status.must_equal 200
          last_response.headers["ETag"].must_equal %Q("#{@aguacate_etag}")
          last_response.headers["Cache-Control"].must_equal "no-cache"
          last_response.headers["Content-Type"].must_equal "application/json"
        end

        it "returns a 404 when data doesn't exist" do
          get "/ilpt-phil/food/steak"
          last_response.status.must_equal 404
          last_response.body.must_equal "Not Found"
        end

      end

      describe "directory listings" do
        before do
          @etag = %Q("#{redis.hget "rs:m:ilpt-phil:food/", "e"}")
        end

        it "returns the correct ETag header" do
          get "/ilpt-phil/food/"
          
          last_response.status.must_equal 200
          last_response.headers["ETag"].must_equal @etag
        end

        it "returns a Cache-Control header with value 'no-cache'" do
          get "/ilpt-phil/food/"

          last_response.status.must_equal 200
          last_response.headers["Cache-Control"].must_equal "no-cache"
        end

        it "responds with 304 when IF_NONE_MATCH header contains the ETag" do
          header "If-None-Match", @etag
          get "/ilpt-phil/food/"

          last_response.status.must_equal 304
        end

        it "contains all items in the directory" do
          get "/ilpt-phil/food/"

          last_response.status.must_equal 200
          last_response.content_type.must_equal "application/ld+json"

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
          content["items"]["desayunos/"].wont_be_nil
          content["items"]["desayunos/"]["ETag"].must_equal "dd36e3cfe52b5f33421150b289a7d48d"
        end

        it "contains all items in the root directory" do
          get "ilpt-phil/"

          last_response.status.must_equal 200
          last_response.content_type.must_equal "application/ld+json"

          content = JSON.parse(last_response.body)
          content["items"]["food/"].wont_be_nil
          %Q("#{content["items"]["food/"]["ETag"]}").must_equal @etag
        end

        it "responds with an empty directory liting when directory doesn't exist" do
          get "ilpt-phil/some-non-existing-dir/"

          last_response.status.must_equal 200
          last_response.content_type.must_equal "application/ld+json"

          content = JSON.parse(last_response.body)
          content["items"].must_equal({})
        end

      end
    end

  end

  describe "HEAD requests" do

    before do
      purge_redis
    end

    context "not authorized" do

      describe "without token" do
        it "says it's not authorized" do
          head "/ilpt-phil/food/camarones"

          last_response.status.must_equal 401
          last_response.body.must_be_empty
        end
      end

      describe "with wrong token" do
        it "says it's not authorized" do
          header "Authorization", "Bearer wrongtoken"
          head "/ilpt-phil/food/camarones"

          last_response.status.must_equal 401
          last_response.body.must_be_empty
        end
      end

    end

    context "authorized" do

      before do
        redis.sadd "authorizations:ilpt-phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put_stub = OpenStruct.new(headers: {
          etag: "bla",
          date: "Fri, 04 Mar 2016 12:20:18 GMT"
        })

        RestClient.stub :put, put_stub do
          put "/ilpt-phil/food/aguacate", "si"
          put "/ilpt-phil/food/camaron", "yummi"
          put "/ilpt-phil/food/desayunos/bolon", "wow"
        end
      end

      describe "directory listings" do
        it "returns the correct header information" do
          get "/ilpt-phil/food/"

          last_response.status.must_equal 200
          last_response.content_type.must_equal "application/ld+json"
          last_response.headers["ETag"].must_equal "\"f9f85fbf5aa1fa378fd79ac8aa0a457d\""
        end
      end

      describe "documents" do
        it "returns a 404 when the document doesn't exist" do
          raises_exception = ->(url, headers) { raise RestClient::ResourceNotFound.new }
          RestClient.stub :head, raises_exception do
            head "/ilpt-phil/food/steak"
          end

          last_response.status.must_equal 404
          last_response.body.must_be_empty
        end
      end

    end

  end

end

