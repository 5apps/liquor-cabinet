require_relative "spec_helper"

describe "App" do
  include Rack::Test::Methods

  def app
    LiquorCabinet
  end

  it "says hello" do
    get "/ohai"
    assert last_response.ok?
    last_response.body.must_include "Ohai."
  end

  it "returns 404 on non-existing routes" do
    get "/virginmargarita"
    last_response.status.must_equal 404
  end
end
