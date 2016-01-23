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
        put_stub = OpenStruct.new(headers: {etag: "bla"})
        RemoteStorage::Swift.stub_any_instance :has_name_collision?, false do
          RestClient.stub :put, put_stub do
            put "/phil/food/aguacate", "si"
          end
        end

        metadata = redis.hgetall "rs_meta:phil:food/aguacate"
        metadata["size"].must_equal "2"
        metadata["type"].must_equal "text/plain; charset=utf-8"
        metadata["etag"].must_equal "bla"
        metadata["modified"].must_equal nil
      end

      it "creates the directory objects metadata in redis" do
        put_stub = OpenStruct.new(headers: {etag: "bla"})
        RemoteStorage::Swift.stub_any_instance :has_name_collision?, false do
          RestClient.stub :put, put_stub do
            put "/phil/food/aguacate", "si"
            put "/phil/food/camaron", "yummi"
          end
        end

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

        put_stub = OpenStruct.new(headers: {etag: "bla"})
        RemoteStorage::Swift.stub_any_instance :has_name_collision?, false do
          RestClient.stub :put, put_stub do
            put "/phil/food/aguacate", "si"
            put "/phil/food/camaron", "yummi"
          end
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
    end

    context "authorized" do
      before do
        redis.sadd "authorizations:phil:amarillo", [":rw"]
        header "Authorization", "Bearer amarillo"

        put_stub = OpenStruct.new(headers: {etag: "bla"})
        RemoteStorage::Swift.stub_any_instance :has_name_collision?, false do
          RestClient.stub :put, put_stub do
            put "/phil/food/aguacate", "si"
            put "/phil/food/camaron", "yummi"
            put "/phil/food/desunyos/bolon", "wow"
          end
        end
      end

      describe "directory listings" do

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
  end
end
