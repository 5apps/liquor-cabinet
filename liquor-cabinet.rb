$LOAD_PATH << File.join(File.expand_path(File.dirname(__FILE__)), 'lib')

require "json"
require "sinatra/base"
require "sinatra/reloader"
require 'haml'

require "configuration"
require "remote_storage/backend_interface"
require "remote_storage/riak"
require "remote_storage/couch_db"

class LiquorCabinet < Sinatra::Base
  BACKENDS = {
    :riak => ::RemoteStorage::Riak,
    :couchdb => ::RemoteStorage::CouchDB
  }

  extend(Configuration)

  after_config_loaded :configure_airbrake

  def self.configure_airbrake
    if @config['airbrake'] && @config['airbrake']['api_key']
      require "airbrake"

      Airbrake.configure do |airbrake|
        airbrake.api_key = @config['airbrake']['api_key']
      end

      use Airbrake::Rack
      enable :raise_errors
    end
  end

  after_config_loaded :setup_backend

  def self.setup_backend
    backend = config['backend']
    unless backend
      raise InvalidConfig.new("backend not given")
    end
    backend_implementation = BACKENDS[backend.to_sym]
    unless backend_implementation
      raise Configuration::Invalid.new("Invalid backend: #{backend}. Valid options are: #{BACKENDS.keys.join(', ')}")
    end

    include(backend_implementation)
  end

  configure :development do
    register Sinatra::Reloader
    enable :logging

    before do
      LiquorCabinet.reload_config
    end

  end

  configure :production do
    enable :logging

    reload_config
  end

  before "/:user/:category/:key" do
    headers 'Access-Control-Allow-Origin' => '*',
            'Access-Control-Allow-Methods' => 'GET, PUT, DELETE',
            'Access-Control-Allow-Headers' => 'Authorization, Content-Type, Origin'
    headers['Access-Control-Allow-Origin'] = env["HTTP_ORIGIN"] if env["HTTP_ORIGIN"]

    p "HEADERS", headers

    @user, @category, @key = params[:user], params[:category], params[:key]
    token = env["HTTP_AUTHORIZATION"] ? env["HTTP_AUTHORIZATION"].split(" ")[1] : ""

    authorize_request(@user, @category, token) unless request.options?
  end

  get "/ohai" do
    "Ohai."
  end

  get '/authenticate/:user' do
    @user = params[:user]
    @redirect_uri = params[:redirect_uri]
    @domain = URI.parse(params[:client_id]).host
    @categories = check_categories(@user, *params[:scope].split(','))
    haml :authenticate
  end

  post '/authenticate/:user' do
    if token = get_auth_token(params[:user], params[:password])
      redirect(build_redirect_uri(token))
    else
      @error = "Failed to authenticate! Please try again."
      haml :authenticate
    end
  end

  get "/airbrake" do
    raise "Ohai, exception from Sinatra app"
  end

  get "/:user/:category/:key" do
    content_type 'application/json'
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

  helpers do

    def build_redirect_uri(token)
      [params[:redirect_uri].sub(/#.*$/, ''),
       '#',
       'access_token=',
       URI.encode_www_form_component(token)].join
    end

  end

end
