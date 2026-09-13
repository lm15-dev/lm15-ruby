# frozen_string_literal: true
require_relative 'lib/lm15/version'
Gem::Specification.new do |spec|
  spec.name = 'lm15'
  spec.version = LM15::VERSION
  spec.authors = ['LM15 contributors']
  spec.summary = 'One canonical interface to language model providers, in native Ruby'
  spec.description = 'LM15 Ruby provides canonical model requests and responses, four provider dialects, streaming, routing, cloud and OAuth credentials, tools, files, caches, batch and video jobs, media generation, and realtime sessions.'
  spec.homepage = 'https://github.com/lm15-dev/lm15-ruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2'
  spec.files = Dir['lib/**/*','bin/*','docs/**/*','examples/**/*'] + %w[LICENSE README.md CHANGELOG.md CONTRACT_PIN CONFORMANCE.md]
  spec.bindir = 'bin'
  spec.executables = ['lm15','lm15-vet']
  spec.require_paths = ['lib']
  spec.metadata = {'source_code_uri'=>spec.homepage,'rubygems_mfa_required'=>'true'}
  # These are Ruby standard-library gems; explicit declarations also work on
  # Ruby versions that stopped installing them as default gems.
  spec.add_dependency 'json', '>= 2.6', '< 4'
  spec.add_dependency 'base64', '>= 0.1', '< 1'
  spec.add_dependency 'net-http', '>= 0.3', '< 1'
  spec.add_dependency 'openssl', '>= 3.0', '< 5'
  spec.add_dependency 'rexml', '>= 3.2.5', '< 4'
end
