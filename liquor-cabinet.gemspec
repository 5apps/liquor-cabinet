# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)

require 'bundler/version'

Gem::Specification.new do |s|
  s.name        = "liquor-cabinet"
  s.version     = "0.0.1"
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Sebastian Kippe"]
  s.email       = ["sebastian@5apps.com"]
  s.homepage    = ""
  s.summary     = ""
  s.description = ""

  s.required_rubygems_version = ">= 1.3.6"

  s.add_dependency('sinatra')
  s.add_dependency('sinatra-contrib')
  s.add_dependency('riak-client')
  s.add_dependency('airbrake')

  s.files        = Dir.glob("{bin,lib}/**/*") + Dir['*.rb']
  # s.executables  = ['config.ru']
  s.require_paths << '.'
end
