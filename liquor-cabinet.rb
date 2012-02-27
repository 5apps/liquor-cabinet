$LOAD_PATH << File.join(File.expand_path(File.dirname(__FILE__)), 'lib')

require "json"
require "sinatra/base"
require "sinatra/reloader"
require "remote_storage/riak"

class LiquorCabinet < Sinatra::Base

  include RemoteStorage::Riak

  configure :development do
    register Sinatra::Reloader
    enable :logging
  end

  configure :development, :test, :production do
    config = File.read(File.expand_path('config.yml', File.dirname(__FILE__)))
    riak_config = YAML.load(config)[ENV['RACK_ENV']]['riak'].symbolize_keys
    set :riak_config, riak_config
  end

  before "/:user/:category/:key" do
    @user, @category, @key = params[:user], params[:category], params[:key]
    token = env["HTTP_AUTHORIZATION"] ? env["HTTP_AUTHORIZATION"].split(" ")[1] : ""

    authorize_request(@user, @category, token)
  end

  get "/ohai" do
    "Ohai."
  end

  get "/headers" do
    env["HTTP_AUTHORIZATION"]
  end

  get "/:user/:category/:key" do
    get_data(@user, @category, @key)
  end

  put "/:user/:category/:key" do
    data = request.body.read
    put_data(@user, @category, @key, data)
  end

  delete "/:user/:category/:key" do
    delete_data(@user, @category, @key)
  end

end
