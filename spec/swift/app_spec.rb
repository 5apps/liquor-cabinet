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
          end
        end

        metadata = redis.hgetall "rs_meta:phil:food/"
        metadata["etag"].must_equal "bla"
        metadata["modified"].length.must_equal 13
        metadata = redis.hgetall "rs_meta:phil:food/"
      end
    end
  end
end

