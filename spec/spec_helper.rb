require 'rubygems'
require 'bundler'
Bundler.require

ENV["RACK_ENV"] = "test"

require_relative '../liquor-cabinet'
require 'minitest/autorun'
require 'rack/test'
require 'purdytest'
require 'riak'

set :environment, :test

config = File.read(File.expand_path('../config.yml', File.dirname(__FILE__)))
riak_config = YAML.load(config)[ENV['RACK_ENV']]['riak'].symbolize_keys
set :riak_config, riak_config

