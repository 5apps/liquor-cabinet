$LOAD_PATH << File.join(File.expand_path(File.dirname(__FILE__)), 'lib')

require "json"
require "sinatra/base"
require 'sinatra/config_file'
require "sinatra/reloader"
require "remote_storage/riak"
require "remote_storage/swift"

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
    also_reload "lib/remote_storage/*.rb"
    enable :logging
  end

  configure :production, :staging do
    require "rack/common_logger"
  end

  #
  # Cabinet doors
  #

  before do
    halt 503 if settings.maintenance rescue false
  end

  ["/:user/*/:key", "/:user/:key", "/:user/*/", "/:user/"].each do |path|
    before path do
      headers 'Access-Control-Allow-Origin' => '*',
              'Access-Control-Allow-Methods' => 'GET, PUT, DELETE',
              'Access-Control-Allow-Headers' => 'Authorization, Content-Type, Origin, If-Match, If-None-Match',
              'Access-Control-Expose-Headers' => 'ETag, Content-Length'
      headers['Access-Control-Allow-Origin'] = env["HTTP_ORIGIN"] if env["HTTP_ORIGIN"]
      headers['Cache-Control'] = 'no-cache'
      headers['Expires'] = '0'

      @user, @key = params[:user], params[:key]
      @directory = params[:splat] && params[:splat].first || ""

      token = env["HTTP_AUTHORIZATION"] ? env["HTTP_AUTHORIZATION"].split(" ")[1] : ""

      storage.authorize_request(@user, @directory, token, @key.blank?) unless request.options?
    end

    options path do
      halt 200
    end
  end

  ["/:user/*/:key", "/:user/:key"].each do |path|
    head path do
      storage.get_head(@user, @directory, @key)
    end

    get path do
      storage.get_data(@user, @directory, @key)
    end

    put path do
      data = request.body.read

      halt 422 unless env['CONTENT_TYPE']

      if env['CONTENT_TYPE'] == "application/x-www-form-urlencoded"
        content_type = "text/plain; charset=utf-8"
      else
        content_type = env['CONTENT_TYPE']
      end

      storage.put_data(@user, @directory, @key, data, content_type)
    end

    delete path do
      storage.delete_data(@user, @directory, @key)
    end
  end

  ["/:user/*/", "/:user/"].each do |path|
    head path do
      storage.get_head_directory_listing(@user, @directory)
    end

    get path do
      storage.get_directory_listing(@user, @directory)
    end
  end

  private

  def storage
    @storage ||= begin
      if settings.respond_to? :riak
        RemoteStorage::Riak.new(settings, self)
      elsif settings.respond_to? :swift
        settings.swift["token"] = File.read("tmp/swift_token.txt")
        RemoteStorage::Swift.new(settings, self)
      else
        puts <<-EOF
You need to set one storage backend in your config.yml file.
Riak and Swift are currently supported. See config.yml.example.
        EOF
      end
    end
  end

end
