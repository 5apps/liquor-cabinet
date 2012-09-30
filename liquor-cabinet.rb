$LOAD_PATH << File.join(File.expand_path(File.dirname(__FILE__)), 'lib')

require "json"
require "sinatra/base"
require "sinatra/reloader"
require "remote_storage/riak"

class LiquorCabinet < Sinatra::Base

  include RemoteStorage::Riak

  def self.config=(config)
    @config = config
    configure_airbrake
  end

  def self.config
    return @config if @config
    config = File.read(File.expand_path('config.yml', File.dirname(__FILE__)))
    self.config = YAML.load(config)[ENV['RACK_ENV']]
  end

  configure :development do
    register Sinatra::Reloader
    enable :logging
    disable :protection
  end

  configure :production do
    disable :logging
    disable :protection
  end

  ["/:user/*/:key", "/:user/*/"].each do |path|
    before path do
      headers 'Access-Control-Allow-Origin' => '*',
              'Access-Control-Allow-Methods' => 'GET, PUT, DELETE',
              'Access-Control-Allow-Headers' => 'Authorization, Content-Type, Origin'
      headers['Access-Control-Allow-Origin'] = env["HTTP_ORIGIN"] if env["HTTP_ORIGIN"]

      @user, @directory, @key = params[:user], params[:splat].first, params[:key]
      token = env["HTTP_AUTHORIZATION"] ? env["HTTP_AUTHORIZATION"].split(" ")[1] : ""

      authorize_request(@user, @directory, token) unless request.options?
    end
  end

  get "/:user/*/:key" do
    get_data(@user, @directory, @key)
  end

  get "/:user/*/" do
    get_directory_listing(@user, @directory)
  end

  put "/:user/*/:key" do
    data = request.body.read

    if env['CONTENT_TYPE'] == "application/x-www-form-urlencoded"
      content_type = "text/plain; charset=utf-8"
    else
      content_type = env['CONTENT_TYPE']
    end

    put_data(@user, @directory, @key, data, content_type)
  end

  delete "/:user/*/:key" do
    delete_data(@user, @directory, @key)
  end

  options "/:user/*/:key" do
    halt 200
  end

  options "/:user/*/" do
    halt 200
  end

  private

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

end
