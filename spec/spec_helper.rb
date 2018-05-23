ENV["RACK_ENV"] = "test"

require 'rubygems'
require 'bundler'
Bundler.require

require_relative '../liquor-cabinet'
require 'minitest/autorun'
require "minitest/stub_any_instance"
require 'rack/test'
require 'purdytest'
require "redis"
require "rest_client"
require "ostruct"
require 'webmock/minitest'

WebMock.disable_net_connect!

def app
  LiquorCabinet
end

app.set :environment, :test

alias context describe

if app.settings.respond_to? :redis
  def redis
    @redis ||= Redis.new(app.settings.redis.symbolize_keys)
  end

  def purge_redis
    redis.keys("rs*").each do |key|
      redis.del key
    end
  end
end

MiniTest::Spec.class_eval do
  def self.shared_examples
    @shared_examples ||= {}
  end
end

module MiniTest::Spec::SharedExamples
  def shared_examples_for(desc, &block)
    MiniTest::Spec.shared_examples[desc] = block
  end

  def it_behaves_like(desc)
    self.instance_eval(&MiniTest::Spec.shared_examples[desc])
  end
end

Object.class_eval { include(MiniTest::Spec::SharedExamples) }

require_relative 'shared_examples'
