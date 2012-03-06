require_relative "spec_helper"
require 'ruby-debug'

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

  before do
    module TestBackend
      class << self
        attr :calls, true
        attr :call_result, true
      end

      %w(get_data put_data delete_data authorize_request
         get_auth_token).each do |m|
        define_method(m) do |*args|
          TestBackend.calls.push([m.to_sym, args])
          TestBackend.call_result
        end
      end
    end

    LiquorCabinet.send(:include, TestBackend)

    TestBackend.calls = []
  end

  describe 'GET /:user/:category/:key' do

    before do
      @token = 'my-test-token'
      get '/foo/bar/baz', {}, 'HTTP_AUTHORIZATION' => "Authorization: #{@token}"
    end

    it "calls get_data with all given parameters" do
      must_have_called(:get_data, 'foo', 'bar', 'baz')
    end

    it "calls authorize_request with the given user, category and token" do
      must_have_called(:authorize_request, 'foo', 'bar', @token)
    end

  end

  describe 'PUT /:user/:category/:key' do

    before do
      @token = 'my-test-token'
      put '/foo/bar/baz', { :test => 'data' }, 'HTTP_AUTHORIZATION' => "Authorization: #{@token}"
    end

    it "calls put_data with all given arguments and the put data" do
      must_have_called(:put_data, 'foo', 'bar', 'baz', 'test=data')
    end

  end

  def must_have_called(method, *args)
    call = find_backend_call(method)
    assert call, "Expected #{method} to be called, but it wasn't."
    call[1].must_equal(args)
  end

  def must_not_have_called(method)
    call = find_backend_call(method)
    assert_not call, "Expected #{method} NOT to be called, but it was (with arguments: #{call[1].inspect})"
  end

  def find_backend_call(method)
    TestBackend.calls.select {|call|
      call[0] == method
    }.first
  end

end
