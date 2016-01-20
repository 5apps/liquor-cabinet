require_relative "spec_helper"

describe "App" do
  include Rack::Test::Methods

  def app
    LiquorCabinet
  end

  it "returns 404 on non-existing routes" do
    get "/virginmargarita"
    last_response.status.must_equal 404
  end

end
