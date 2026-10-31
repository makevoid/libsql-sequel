# frozen-string-literal: true

require 'rake/testtask'

Rake::TestTask.new do |t|
  t.libs << 'test'
  t.pattern = 'test/**/*_test.rb'
end

task :default => :test

desc 'Run Sequel upstream SQLite and integration specs (requires tmp/upstream/sequel)'
task :upstream do
  ruby 'test/upstream.rb'
end

desc 'Run opt-in HTTP/Turso tests using LIBSQL_TEST_URL and LIBSQL_TEST_AUTH_TOKEN'
task :remote do
  ruby '-Ilib', 'test/remote.rb'
end

desc 'Run the native HTTP tests against the local upstream Hrana fixture'
task :remote_local do
  sh({'LIBSQL_TEST_URL' => 'http://localhost:8080', 'LIBSQL_TEST_AUTH_TOKEN' => ''},
    'tmp/hrana-venv/bin/python', 'test/support/hrana_server.py',
    RbConfig.ruby, '-Ilib', 'test/remote.rb')
end
