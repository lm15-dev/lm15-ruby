# frozen_string_literal: true
require 'rake/testtask'
Rake::TestTask.new do |test|
  test.libs << 'lib' << 'test'
  test.pattern = 'test/**/*_test.rb'
  test.warning = true
end
task default: :test

desc 'Build the standalone Ruby gem'
task :build do
  ruby '-S', 'gem', 'build', 'lm15.gemspec'
end

desc 'Run the unchanged pinned contract harness (CONTRACT=/path/to/clean/checkout)'
task :contract do
  require 'rbconfig'
  sh 'python', 'tools/check_contract.py', '--contract', ENV.fetch('CONTRACT'), '--ruby', RbConfig.ruby, '--direction', 'all'
end
