require_relative "../spec_helper"
require 'minitest/hooks'

describe "App" do
  include Rack::Test::Methods
  include Minitest::Hooks

  def app
    LiquorCabinet
  end

  def base_url
    app.settings.couchdb['uri']
  end

  before(:all) do
    RestClient.put(base_url, "")
  end

  before do
    header "X-Storage-Backend", "couchdb"
  end

  after(:all) do
    purge_redis

    RestClient.delete(base_url)
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

      after do
        delete "/ilpt-phil/food/aguacate"
        delete "/ilpt-phil/food/camaron"
      end

      it "creates the metadata object in redis" do
        put "/ilpt-phil/food/aguacate", "si"

        aguacate_etag = etag_for('ilpt-phil/food/aguacate').gsub('"', '')

        metadata = redis.hgetall "rs:m:ilpt-phil:food/aguacate"
        metadata["s"].must_equal "2"
        metadata["t"].must_equal "text/plain; charset=utf-8"
        metadata["e"].must_equal aguacate_etag
        metadata["m"].length.must_equal 13
      end

      it "creates the directory objects metadata in redis" do
        RemoteStorage::CouchDB.stub_any_instance :etag_for, "newetag" do
          put "/ilpt-phil/food/aguacate", "si"
          put "/ilpt-phil/food/camaron", "yummi"
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
        it "is 201 for newly created objects" do
          put "/ilpt-phil/food/aguacate", "muy deliciosa"

          last_response.status.must_equal 201
        end

        it "is 200 for updated objects" do
          put "/ilpt-phil/food/aguacate", "deliciosa"
          put "/ilpt-phil/food/aguacate", "muy deliciosa"

          last_response.status.must_equal 200
        end
      end

      context "logging usage size" do
        it "logs the complete size when creating new objects" do
          put "/ilpt-phil/food/aguacate", "1234567890"

          size_log = redis.get "rs:s:ilpt-phil"
          size_log.must_equal "10"
        end

        it "logs the size difference when updating existing objects" do
          put "/ilpt-phil/food/camaron",  "1234567890"
          put "/ilpt-phil/food/aguacate", "1234567890"
          put "/ilpt-phil/food/aguacate", "123"

          size_log = redis.get "rs:s:ilpt-phil"
          size_log.must_equal "13"
        end
      end

      describe "objects in root dir" do
        before do
          put "/ilpt-phil/bamboo.txt", "shir kan"
        end

        it "are listed in the directory listing with all metadata" do
          get "ilpt-phil/"

          last_response.status.must_equal 200
          last_response.content_type.must_equal "application/ld+json"

          content = JSON.parse(last_response.body)
          bamboo_etag = etag_for('ilpt-phil/bamboo.txt').gsub('"', '')

          content["items"]["bamboo.txt"].wont_be_nil
          content["items"]["bamboo.txt"]["ETag"].must_equal bamboo_etag
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
          put "/ilpt-phil/food/aguacate", "si"
          put "/ilpt-phil/food", "wontwork"

          last_response.status.must_equal 409
          last_response.body.must_equal "Conflict"

          metadata = redis.hgetall "rs:m:ilpt-phil:food"
          metadata.must_be_empty
        end

        it "conflicts when there is a document with same name as directory" do
          put "/ilpt-phil/food/aguacate", "si"
          put "/ilpt-phil/food/aguacate/empanado", "wontwork"

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
          put "/ilpt-phil/food/aguacate", "si"
        end

        it "allows the request if the header matches the current ETag" do
          old_etag = etag_for "ilpt-phil/food/aguacate"
          header "If-Match", old_etag

          put "/ilpt-phil/food/aguacate", "aye"
          new_etag = etag_for "ilpt-phil/food/aguacate"

          last_response.status.must_equal 200
          last_response.headers["Etag"].must_equal new_etag
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
          header "If-None-Match", "*"

          put "/ilpt-phil/food/aguacate", "si"

          last_response.status.must_equal 201
        end

        it "fails the request if the document already exsits" do
          put "/ilpt-phil/food/aguacate", "si"

          header "If-None-Match", "*"
          put "/ilpt-phil/food/aguacate", "si"

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

        put "/ilpt-phil/food/aguacate", "si"
        put "/ilpt-phil/food/camaron", "yummi"
        put "/ilpt-phil/food/desayunos/bolon", "wow"
      end

      after do
        delete "/ilpt-phil/food/aguacate"
        delete "/ilpt-phil/food/camaron"
        delete "/ilpt-phil/food/desayunos/bolon"
      end

      it "decreases the size log by size of deleted object" do
        RemoteStorage::CouchDB.stub_any_instance :etag_for, "rootetag" do
          delete "/ilpt-phil/food/aguacate"
        end

        size_log = redis.get "rs:s:ilpt-phil"
        size_log.must_equal "8"
      end

      it "deletes the metadata object in redis" do
        RemoteStorage::CouchDB.stub_any_instance :etag_for, "rootetag" do
          delete "/ilpt-phil/food/aguacate"
        end

        metadata = redis.hgetall "rs:m:ilpt-phil:food/aguacate"
        metadata.must_be_empty
      end

      it "deletes the directory objects metadata in redis" do
        old_metadata = redis.hgetall "rs:m:ilpt-phil:food/"

        RemoteStorage::CouchDB.stub_any_instance :etag_for, "newetag" do
          delete "/ilpt-phil/food/aguacate"
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
        RemoteStorage::CouchDB.stub_any_instance :etag_for, "rootetag" do
          delete "/ilpt-phil/food/aguacate"
          delete "/ilpt-phil/food/camaron"
          delete "/ilpt-phil/food/desayunos/bolon"
        end

        redis.smembers("rs:m:ilpt-phil:food/desayunos:items").must_be_empty
        redis.hgetall("rs:m:ilpt-phil:food/desayunos/").must_be_empty

        redis.smembers("rs:m:ilpt-phil:food/:items").must_be_empty
        redis.hgetall("rs:m:ilpt-phil:food/").must_be_empty

        redis.smembers("rs:m:ilpt-phil:/:items").must_be_empty
      end

      it "responds with the ETag of the deleted item in the header" do
        aguacate_etag = etag_for('ilpt-phil/food/aguacate')

        delete "/ilpt-phil/food/aguacate"

        last_response.headers["ETag"].must_equal aguacate_etag
      end

      context "when item doesn't exist" do
        before do
          put "/ilpt-phil/food/steak", "si"
          delete "/ilpt-phil/food/steak"
        end

        it "returns a 404" do
          get "/ilpt-phil/food/steak"
          last_response.status.must_equal 404
          last_response.body.must_equal "Not Found"
        end

        it "deletes any metadata that might still exist" do
          delete "/ilpt-phil/food/aguacate"
          delete "/ilpt-phil/food/camaron"
          delete "/ilpt-phil/food/desayunos/bolon"

          put "/ilpt-phil/food/steak", "si"
          delete "/ilpt-phil/food/steak"

          metadata = redis.hgetall "rs:m:ilpt-phil:food/steak"
          metadata.must_be_empty

          redis.smembers("rs:m:ilpt-phil:food/:items").must_be_empty
          redis.hgetall("rs:m:ilpt-phil:food/").must_be_empty

          redis.smembers("rs:m:ilpt-phil:/:items").must_be_empty
        end
      end

      describe "If-Match header" do
        it "succeeds when the header matches the current ETag" do
          etag = etag_for "ilpt-phil/food/aguacate"

          header "If-Match", etag

          delete "/ilpt-phil/food/aguacate"

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

        put "/ilpt-phil/food/aguacate", "si"
        put "/ilpt-phil/food/camaron", "yummi"
        put "/ilpt-phil/food/desayunos/bolon", "wow"

        @aguacate_etag = etag_for('ilpt-phil/food/aguacate')
      end

      after do
        delete "/ilpt-phil/food/aguacate"
        delete "/ilpt-phil/food/camaron"
        delete "/ilpt-phil/food/desayunos/bolon"
      end

      describe "documents" do

        it "returns the required response headers" do
          get "/ilpt-phil/food/aguacate"

          last_response.status.must_equal 200
          last_response.headers["ETag"].must_equal @aguacate_etag
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

          aguacate_etag = etag_for('ilpt-phil/food/aguacate').gsub('"', '')
          content["items"]["aguacate"].wont_be_nil
          content["items"]["aguacate"]["Content-Type"].must_equal "text/plain; charset=utf-8"
          content["items"]["aguacate"]["Content-Length"].must_equal 2
          content["items"]["aguacate"]["ETag"].must_equal aguacate_etag

          camaron_etag = etag_for('ilpt-phil/food/camaron').gsub('"', '')
          content["items"]["camaron"].wont_be_nil
          content["items"]["camaron"]["Content-Type"].must_equal "text/plain; charset=utf-8"
          content["items"]["camaron"]["Content-Length"].must_equal 5
          content["items"]["camaron"]["ETag"].must_equal camaron_etag

          desayunos_etag = redis.hget "rs:m:ilpt-phil:food/desayunos/", "e"
          content["items"]["desayunos/"].wont_be_nil
          content["items"]["desayunos/"]["ETag"].must_equal desayunos_etag
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

        put "/ilpt-phil/food/aguacate", "si"
        put "/ilpt-phil/food/camaron", "yummi"
        put "/ilpt-phil/food/desayunos/bolon", "wow"
      end

      after do
        delete "/ilpt-phil/food/aguacate"
        delete "/ilpt-phil/food/camaron"
        delete "/ilpt-phil/food/desayunos/bolon"
      end

      describe "directory listings" do
        it "returns the correct header information" do
          get "/ilpt-phil/food/"

          etag = %Q("#{redis.hget "rs:m:ilpt-phil:food/", "e"}")

          last_response.status.must_equal 200
          last_response.content_type.must_equal "application/ld+json"
          last_response.headers["ETag"].must_equal etag
        end
      end

      describe "documents" do
        it "returns a 404 when the document doesn't exist" do
          head "/ilpt-phil/food/steak"

          last_response.status.must_equal 404
          last_response.body.must_be_empty
        end
      end

    end

  end

end

