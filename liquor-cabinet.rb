$LOAD_PATH << File.join(File.expand_path(File.dirname(__FILE__)), 'lib')

require "json"
require "sinatra/base"
require 'sinatra/config_file'
require "sinatra/reloader"
require "remote_storage/riak"

# Disable Rack logger completely
module Rack
  class CommonLogger
    def call(env)
      # do nothing
      @app.call(env)
    end
  end
end

class LiquorCabinet < Sinatra::Base

  #
  # Configuration
  #

  configure do
    disable :protection, :logging
    enable :dump_errors

    register Sinatra::ConfigFile
    set :environments, %w{development test production staging}
    config_file 'config.yml'
  end

  configure :development do
    register Sinatra::Reloader
    enable :logging
  end

  if settings.riak
    include RemoteStorage::Riak
  # elsif settings.redis
  #  include RemoteStorage::Redis
  # end
  end

  #
  # Cabinet doors
  #

  ["/:user/*/:key", "/:user/:key", "/:user/*/", "/:user/"].each do |path|
    before path do
      headers 'Access-Control-Allow-Origin' => '*',
              'Access-Control-Allow-Methods' => 'GET, PUT, DELETE',
              'Access-Control-Allow-Headers' => 'Authorization, Content-Type, Origin'
      headers['Access-Control-Allow-Origin'] = env["HTTP_ORIGIN"] if env["HTTP_ORIGIN"]
      headers['Cache-Control'] = 'no-cache'

      @user, @key = params[:user], params[:key]
      @directory = params[:splat] && params[:splat].first || ""

      token = env["HTTP_AUTHORIZATION"] ? env["HTTP_AUTHORIZATION"].split(" ")[1] : ""

      authorize_request(@user, @directory, token, @key.blank?) unless request.options?
    end
  end

  ["/:user/*/:key", "/:user/:key"].each do |path|
    get path do
      get_data(@user, @directory, @key)
    end
  end

  ["/:user/*/", "/:user/"].each do |path|
    get path do
      get_directory_listing(@user, @directory)
    end
  end

  ["/:user/*/:key", "/:user/:key"].each do |path|
    put path do
      data = request.body.read

      if env['CONTENT_TYPE'] == "application/x-www-form-urlencoded"
        content_type = "text/plain; charset=utf-8"
      else
        content_type = env['CONTENT_TYPE']
      end

      put_data(@user, @directory, @key, data, content_type)
    end
  end

  ["/:user/*/:key", "/:user/:key"].each do |path|
    delete path do
      delete_data(@user, @directory, @key)
    end
  end

  ["/:user/*/:key", "/:user/:key", "/:user/*/", "/:user/"].each do |path|
    options path do
      halt 200
    end
  end

end
