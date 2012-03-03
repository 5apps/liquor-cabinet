$LOAD_PATH << File.join(File.expand_path(File.dirname(__FILE__)), 'lib')

require "json"
require "sinatra/base"
require "sinatra/reloader"
require "remote_storage/riak"

class LiquorCabinet < Sinatra::Base

  include RemoteStorage::Riak

  def self.config=(config)
    @config = config
  end

  def self.config
    return @config if @config
    config = File.read(File.expand_path('config.yml', File.dirname(__FILE__)))
    @config = YAML.load(config)[ENV['RACK_ENV']]
  end

  configure :development do
    register Sinatra::Reloader
    enable :logging
  end

  configure :production do
    disable :logging
  end

  before "/:user/:category/:key" do
    headers 'Access-Control-Allow-Origin' => '*',
            'Access-Control-Allow-Methods' => 'GET, PUT, DELETE',
            'Access-Control-Allow-Headers' => 'Authorization, Content-Type, Origin'
    headers['Access-Control-Allow-Origin'] = env["HTTP_ORIGIN"] if env["HTTP_ORIGIN"]

    @user, @category, @key = params[:user], params[:category], params[:key]
    token = env["HTTP_AUTHORIZATION"] ? env["HTTP_AUTHORIZATION"].split(" ")[1] : ""

    authorize_request(@user, @category, token) unless request.options?
  end

  get "/ohai" do
    "Ohai."
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

  options "/:user/:category/:key" do
    halt 200
  end

end
