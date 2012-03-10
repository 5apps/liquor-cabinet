require 'rubygems'
require 'bundler'

ENV["RACK_ENV"] = "test"

Bundler.require

require_relative '../liquor-cabinet'
require 'minitest/autorun'
require 'rack/test'
require 'purdytest'

set :environment, :test


