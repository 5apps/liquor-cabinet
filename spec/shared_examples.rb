shared_examples_for 'a REST adapter' do
  include Rack::Test::Methods

  def container_url_for(user)
    raise NotImplementedError
  end

  def storage_class
    raise NotImplementedError
  end

  it "returns 404 on non-existing routes" do
    get "/virginmargarita"
    _(last_response.status).must_equal 404
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
        put "/phil/food/aguacate", "si"

        metadata = redis.hgetall "rs:m:phil:food/aguacate"
        _(metadata["s"]).must_equal "2"
        _(metadata["t"]).must_equal "text/plain; charset=utf-8"
        _(metadata["e"]).must_equal "0815etag"
        _(metadata["m"].length).must_equal 13
      end

      it "updates the metadata object in redis when it changes" do
        put "/phil/food/banano", "si"
        put "/phil/food/banano", "oh, no"

        metadata = redis.hgetall "rs:m:phil:food/banano"
        _(metadata["s"]).must_equal "6"
        _(metadata["t"]).must_equal "text/plain; charset=utf-8"
        _(metadata["e"]).must_equal "0817etag"
        _(metadata["m"]).must_equal "1457094020000"
      end

      it "creates the directory objects metadata in redis" do
        put "/phil/food/aguacate", "si"
        put "/phil/food/camaron", "yummi"

        metadata = redis.hgetall "rs:m:phil:/"
        _(metadata["e"]).must_equal "fe2976909daaf074660981ab563fe65d"
        _(metadata["m"].length).must_equal 13

        metadata = redis.hgetall "rs:m:phil:food/"
        _(metadata["e"]).must_equal "926f98ff820f2f9764fd3c60a22865ad"
        _(metadata["m"].length).must_equal 13

        food_items = redis.smembers "rs:m:phil:food/:items"
        food_items.each do |food_item|
          _(["camaron", "aguacate"]).must_include food_item
        end

        root_items = redis.smembers "rs:m:phil:/:items"
        _(root_items).must_equal ["food/"]
      end

      context "response code" do
        it "is 201 for newly created objects" do
          put "/phil/food/aguacate", "ci"

          _(last_response.status).must_equal 201
        end

        it "is 200 for updated objects" do
          put "/phil/food/aguacate", "deliciosa"
          put "/phil/food/aguacate", "muy deliciosa"

          _(last_response.status).must_equal 200
        end
      end

      context "logging usage size" do
        it "logs the complete size when creating new objects" do
          put "/phil/food/aguacate", "1234567890"

          size_log = redis.get "rs:s:phil"
          _(size_log).must_equal "10"
        end

        it "logs the size difference when updating existing objects" do
          put "/phil/food/camaron",  "1234567890"
          put "/phil/food/aguacate", "1234567890"
          put "/phil/food/aguacate", "123"

          size_log = redis.get "rs:s:phil"
          _(size_log).must_equal "13"
        end
      end

      describe "objects in root dir" do
        before do
          put "/phil/bamboo.txt", "shir kan"
        end

        it "are listed in the directory listing with all metadata" do
          get "phil/"

          _(last_response.status).must_equal 200
          _(last_response.content_type).must_equal "application/ld+json"

          content = JSON.parse(last_response.body)
          _(content["items"]["bamboo.txt"]).wont_be_nil
          _(content["items"]["bamboo.txt"]["ETag"]).must_equal "0818etag"
          _(content["items"]["bamboo.txt"]["Content-Type"]).must_equal "text/plain; charset=utf-8"
          _(content["items"]["bamboo.txt"]["Content-Length"]).must_equal 8
          _(content["items"]["bamboo.txt"]["Last-Modified"]).must_equal "Fri, 04 Mar 2016 12:20:18 GMT"
        end
      end

      describe "name collision checks" do
        it "is successful when there is no name collision" do
          put "/phil/food/aguacate", "si"

          _(last_response.status).must_equal 201

          metadata = redis.hgetall "rs:m:phil:food/aguacate"
          _(metadata["s"]).must_equal "2"
        end

        it "conflicts when there is a directory with same name as document" do
          put "/phil/food/aguacate", "si"
          put "/phil/food", "wontwork"

          _(last_response.status).must_equal 409
          _(last_response.body).must_equal "Conflict"

          metadata = redis.hgetall "rs:m:phil:food"
          _(metadata).must_be_empty
        end

        it "conflicts when there is a document with same name as directory" do
          put "/phil/food/aguacate", "si"
          put "/phil/food/aguacate/empanado", "wontwork"

          _(last_response.status).must_equal 409

          metadata = redis.hgetall "rs:m:phil:food/aguacate/empanado"
          _(metadata).must_be_empty
        end

        it "returns 400 when a Content-Range header is sent" do
          header "Content-Range", "bytes 0-3/3"

          put "/phil/food/aguacate", "si"

          _(last_response.status).must_equal 400
        end
      end

      describe "If-Match header" do
        before do
          put "/phil/food/aguacate", "si"
        end

        it "allows the request if the header matches the current ETag" do
          header "If-Match", "\"0815etag\""

          put "/phil/food/aguacate", "aye"

          _(last_response.status).must_equal 200
          _(last_response.headers["Etag"]).must_equal "\"0915etag\""
        end

        it "allows the request if the header contains a weak ETAG matching the current ETag" do
          header "If-Match", "W/\"0815etag\""

          put "/phil/food/aguacate", "aye"

          _(last_response.status).must_equal 200
          _(last_response.headers["Etag"]).must_equal "\"0915etag\""
        end

        it "allows the request if the header contains a weak ETAG with leading quote matching the current ETag" do
          header "If-Match", "\"W/\"0815etag\""

          put "/phil/food/aguacate", "aye"

          _(last_response.status).must_equal 200
          _(last_response.headers["Etag"]).must_equal "\"0915etag\""
        end

        it "fails the request if the header does not match the current ETag" do
          header "If-Match", "someotheretag"

          put "/phil/food/aguacate", "aye"

          _(last_response.status).must_equal 412
          _(last_response.body).must_equal "Precondition Failed"
        end

        it "allows the request if redis metadata became out of sync" do
          header "If-Match", "\"0815etag\""

          put "/phil/food/aguacate", "aye"

          _(last_response.status).must_equal 200
        end
      end

      describe "If-None-Match header set to '*'" do
        it "succeeds when the document doesn't exist yet" do
          header "If-None-Match", "*"

          put "/phil/food/aguacate", "si"

          _(last_response.status).must_equal 201
        end

        it "fails the request if the document already exists" do
          put "/phil/food/aguacate", "si"

          header "If-None-Match", "*"
          put "/phil/food/aguacate", "si"

          _(last_response.status).must_equal 412
          _(last_response.body).must_equal "Precondition Failed"
        end
      end

      describe "Content-Type" do
        it "must be in the type/subtype format" do
          header "Content-Type", "text"

          put "/phil/food/invalid_content_type", "invalid"

          _(last_response.status).must_equal 415
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
          delete "/phil/food/aguacate"

          _(last_response.status).must_equal 401
          _(last_response.body).must_equal "Unauthorized"
        end
      end

      describe "with empty token" do
        it "says it's not authorized" do
          header "Authorization", "Bearer "
          delete "/phil/food/aguacate"

          _(last_response.status).must_equal 401
          _(last_response.body).must_equal "Unauthorized"
        end
      end

      describe "with wrong token" do
        it "says it's not authorized" do
          header "Authorization", "Bearer wrongtoken"
          delete "/phil/food/aguacate"

          _(last_response.status).must_equal 401
          _(last_response.body).must_equal "Unauthorized"
        end
      end

    end

    context "authorized" do
      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put "/phil/food/aguacate", "si"
        put "/phil/food/camaron", "yummi"
        put "/phil/food/desayunos/bolon", "wow"
      end

      it "decreases the size log by size of deleted object" do
        delete "/phil/food/aguacate"

        size_log = redis.get "rs:s:phil"
        _(size_log).must_equal "8"
      end

      it "deletes the metadata object in redis" do
        delete "/phil/food/aguacate"

        metadata = redis.hgetall "rs:m:phil:food/aguacate"
        _(metadata).must_be_empty
      end

      it "deletes the directory objects metadata in redis" do
        old_metadata = redis.hgetall "rs:m:phil:food/"

        storage_class.stub_any_instance :etag_for, "newetag" do
          delete "/phil/food/aguacate"
        end

        metadata = redis.hgetall "rs:m:phil:food/"
        _(metadata["e"]).must_equal "newetag"
        _(metadata["m"].length).must_equal 13
        _(metadata["m"]).wont_equal old_metadata["m"]

        food_items = redis.smembers "rs:m:phil:food/:items"
        _(food_items.sort).must_equal ["camaron", "desayunos/"]

        root_items = redis.smembers "rs:m:phil:/:items"
        _(root_items).must_equal ["food/"]
      end

      it "deletes the parent directory objects metadata when deleting all items" do
        delete "/phil/food/aguacate"
        delete "/phil/food/camaron"
        delete "/phil/food/desayunos/bolon"

        _(redis.smembers("rs:m:phil:food/desayunos:items")).must_be_empty
        _(redis.hgetall("rs:m:phil:food/desayunos/")).must_be_empty

        _(redis.smembers("rs:m:phil:food/:items")).must_be_empty
        _(redis.hgetall("rs:m:phil:food/")).must_be_empty

        _(redis.smembers("rs:m:phil:/:items")).must_be_empty
      end

      it "responds with the ETag of the deleted item in the header" do
        delete "/phil/food/aguacate"

        _(last_response.headers["ETag"]).must_equal "\"0815etag\""
      end

      context "when item doesn't exist" do
        before do
          purge_redis

          delete "/phil/food/steak"
        end

        it "returns a 404" do
          _(last_response.status).must_equal 404
          _(last_response.body).must_equal "Not Found"
        end

        it "deletes any metadata that might still exist" do
          delete "/phil/food/steak"

          metadata = redis.hgetall "rs:m:phil:food/steak"
          _(metadata).must_be_empty

          _(redis.smembers("rs:m:phil:food/:items")).must_be_empty
          _(redis.hgetall("rs:m:phil:food/")).must_be_empty

          _(redis.smembers("rs:m:phil:/:items")).must_be_empty
        end
      end

      describe "If-Match header" do
        it "succeeds when the header matches the current ETag" do
          header "If-Match", "\"0815etag\""

          delete "/phil/food/aguacate"

          _(last_response.status).must_equal 200
        end

        it "succeeds when the header contains a weak ETAG matching the current ETag" do
          header "If-Match", "W/\"0815etag\""

          delete "/phil/food/aguacate"

          _(last_response.status).must_equal 200
        end

        it "fails the request if it does not match the current ETag" do
          header "If-Match", "someotheretag"

          delete "/phil/food/aguacate"

          _(last_response.status).must_equal 412
          _(last_response.body).must_equal "Precondition Failed"
        end
      end
    end
  end

  describe "GET requests" do

    before do
      purge_redis
    end

    context "requests to public resources" do
      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"
      end

      describe "normal request" do
        before do
          header "Content-Type", "image/jpeg"

          put "/phil/public/shares/example.jpg", ""
        end

        it "returns the required response headers" do
          get "/phil/public/shares/example.jpg"

          _(last_response.status).must_equal 200
          _(last_response.headers["Content-Type"]).must_equal "image/jpeg"
        end
      end

      describe "partial request" do
        before do
          header "Content-Type", "image/jpeg"

          put "/phil/public/shares/example_partial.jpg", <<-EOF
JFIFddDuckyA␍⎺␉␊␍
#%'%#//33//@@@@@@@@@@@@@@@&&0##0+.'''.+550055@@?@@@@@@@@@@@>"!1AQaq"2B
          EOF
        end

        it "returns the required response headers" do
          header 'Range', 'bytes=0-16'
          get "/phil/public/shares/example_partial.jpg"

          _(last_response.status).must_equal 206
          _(last_response.headers["Content-Type"]).must_equal "image/jpeg"
        end
      end
    end

    context "not authorized" do

      describe "without token" do
        it "says it's not authorized" do
          get "/phil/food/"

          _(last_response.status).must_equal 401
          _(last_response.body).must_equal "Unauthorized"
        end
      end

      describe "with wrong token" do
        it "says it's not authorized" do
          header "Authorization", "Bearer wrongtoken"
          get "/phil/food/"

          _(last_response.status).must_equal 401
          _(last_response.body).must_equal "Unauthorized"
        end
      end

    end

    context "authorized" do

      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put "/phil/food/aguacate", "si"
        put "/phil/food/camaron", "yummi"
        put "/phil/food/desayunos/bolon", "wow"
      end

      describe "documents" do

        it "returns the required response headers" do
          get "/phil/food/aguacate"

          _(last_response.status).must_equal 200
          # ETag is coming from the Redis metadata, not the storage server (which has "0817etag")
          _(last_response.headers["ETag"]).must_equal "\"0815etag\""
          _(last_response.headers["Cache-Control"]).must_equal "no-cache"
          _(last_response.headers["Content-Type"]).must_equal "text/plain; charset=utf-8"
        end

        it "returns a 404 when data doesn't exist" do
          get "/phil/food/steak"

          _(last_response.status).must_equal 404
          _(last_response.body).must_equal "Not Found"
        end

        it "responds with 304 when IF_NONE_MATCH header contains the ETag" do
          header "If-None-Match", "\"0815etag\""

          get "/phil/food/aguacate"

          _(last_response.status).must_equal 304
          _(last_response.headers["ETag"]).must_equal "\"0815etag\""
          _(last_response.headers["Last-Modified"]).must_equal "Fri, 04 Mar 2016 12:20:18 GMT"
        end

        it "responds with 304 when IF_NONE_MATCH header contains weak ETAG matching the current ETag" do
          header "If-None-Match", "W/\"0815etag\""

          get "/phil/food/aguacate"

          _(last_response.status).must_equal 304
          _(last_response.headers["ETag"]).must_equal "\"0815etag\""
          _(last_response.headers["Last-Modified"]).must_equal "Fri, 04 Mar 2016 12:20:18 GMT"
        end

      end

      describe "directory listings" do

        it "returns the correct ETag header" do
          get "/phil/food/"

          _(last_response.status).must_equal 200
          _(last_response.headers["ETag"]).must_equal "\"f9f85fbf5aa1fa378fd79ac8aa0a457d\""
        end

        it "returns a Cache-Control header with value 'no-cache'" do
          get "/phil/food/"

          _(last_response.status).must_equal 200
          _(last_response.headers["Cache-Control"]).must_equal "no-cache"
        end

        it "responds with 304 when IF_NONE_MATCH header contains the ETag" do
          header "If-None-Match", "\"f9f85fbf5aa1fa378fd79ac8aa0a457d\""
          get "/phil/food/"

          _(last_response.status).must_equal 304
        end

        it "responds with 304 when IF_NONE_MATCH header contains weak ETAG matching the ETag" do
          header "If-None-Match", "W/\"f9f85fbf5aa1fa378fd79ac8aa0a457d\""
          get "/phil/food/"

          _(last_response.status).must_equal 304
        end

        it "contains all items in the directory" do
          get "/phil/food/"

          _(last_response.status).must_equal 200
          _(last_response.content_type).must_equal "application/ld+json"

          content = JSON.parse(last_response.body)
          _(content["@context"]).must_equal "http://remotestorage.io/spec/folder-description"
          _(content["items"]["aguacate"]).wont_be_nil
          _(content["items"]["aguacate"]["Content-Type"]).must_equal "text/plain; charset=utf-8"
          _(content["items"]["aguacate"]["Content-Length"]).must_equal 2
          _(content["items"]["aguacate"]["ETag"]).must_equal "0815etag"
          _(content["items"]["camaron"]).wont_be_nil
          _(content["items"]["camaron"]["Content-Type"]).must_equal "text/plain; charset=utf-8"
          _(content["items"]["camaron"]["Content-Length"]).must_equal 5
          _(content["items"]["camaron"]["ETag"]).must_equal "0816etag"
          _(content["items"]["desayunos/"]).wont_be_nil
          _(content["items"]["desayunos/"]["ETag"]).must_equal "dd36e3cfe52b5f33421150b289a7d48d"
        end

        it "contains all items in the root directory" do
          get "phil/"

          _(last_response.status).must_equal 200
          _(last_response.content_type).must_equal "application/ld+json"

          content = JSON.parse(last_response.body)
          _(content["items"]["food/"]).wont_be_nil
          _(content["items"]["food/"]["ETag"]).must_equal "f9f85fbf5aa1fa378fd79ac8aa0a457d"
        end

        it "responds with an empty directory liting when directory doesn't exist" do
          get "phil/some-non-existing-dir/"

          _(last_response.status).must_equal 200
          _(last_response.content_type).must_equal "application/ld+json"

          content = JSON.parse(last_response.body)
          _(content["items"]).must_equal({})
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
          head "/phil/food/camarones"

          _(last_response.status).must_equal 401
          _(last_response.body).must_be_empty
        end
      end

      describe "with wrong token" do
        it "says it's not authorized" do
          header "Authorization", "Bearer wrongtoken"
          head "/phil/food/camarones"

          _(last_response.status).must_equal 401
          _(last_response.body).must_be_empty
        end
      end

    end

    context "authorized" do

      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put "/phil/food/aguacate", "si"
        put "/phil/food/camaron", "yummi"
        put "/phil/food/desayunos/bolon", "wow"
      end

      describe "directory listings" do
        it "returns the correct header information" do
          get "/phil/food/"

          _(last_response.status).must_equal 200
          _(last_response.content_type).must_equal "application/ld+json"
          _(last_response.headers["ETag"]).must_equal "\"f9f85fbf5aa1fa378fd79ac8aa0a457d\""
        end
      end

      describe "documents" do
        context "when the document doesn't exist" do
          it "returns a 404" do
            head "/phil/food/steak"

            _(last_response.status).must_equal 404
            _(last_response.body).must_be_empty
          end
        end

        context "when the document exists" do
          it "returns the required response headers" do
            head "/phil/food/aguacate"

            _(last_response.status).must_equal 200
            _(last_response.headers["ETag"]).must_equal "\"0815etag\""
            _(last_response.headers["Cache-Control"]).must_equal "no-cache"
            _(last_response.headers["Last-Modified"]).must_equal "Fri, 04 Mar 2016 12:20:18 GMT"
            _(last_response.headers["Content-Type"]).must_equal "text/plain; charset=utf-8"
            _(last_response.headers["Content-Length"]).must_equal "2"
          end

          it "responds with 304 when IF_NONE_MATCH header contains the ETag" do
            header "If-None-Match", "\"0815etag\""

            head "/phil/food/aguacate"

            _(last_response.status).must_equal 304
            _(last_response.headers["ETag"]).must_equal "\"0815etag\""
            _(last_response.headers["Last-Modified"]).must_equal "Fri, 04 Mar 2016 12:20:18 GMT"
          end

          it "responds with 304 when IF_NONE_MATCH header contains weak ETAG matching the current ETag" do
            header "If-None-Match", "W/\"0815etag\""

            head "/phil/food/aguacate"

            _(last_response.status).must_equal 304
            _(last_response.headers["ETag"]).must_equal "\"0815etag\""
            _(last_response.headers["Last-Modified"]).must_equal "Fri, 04 Mar 2016 12:20:18 GMT"
          end
        end
      end
    end
  end
end
