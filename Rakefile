# frozen-string-literal: true

require 'rake/testtask'

RUBY_WARNING_FLAGS = ['-w'].freeze
STRICT_BLOCK_WARNING_FLAGS = RUBY_VERSION >= '3.4' ? ['-W:strict_unused_block'].freeze : [].freeze

Rake::TestTask.new do |t|
  t.libs << 'test'
  t.pattern = 'test/**/*_test.rb'
  t.warning = true
  t.ruby_opts.concat(STRICT_BLOCK_WARNING_FLAGS)
end

task :default => :check

desc 'Run syntax and method-visibility checks, then warning-enabled native tests'
task :check => [:lint, :test]

desc 'Run the syntax and method-visibility checks used by Sequel'
task :lint => [:check_syntax, :check_visibility]

desc 'Check Ruby syntax with warnings (project files only)'
task :check_syntax do
  require 'open3'
  files = FileList['lib/**/*.rb', 'test/**/*.rb', 'examples/**/*.rb', 'tasks/**/*.rb', '*.gemspec', 'Gemfile', 'Rakefile'].sort
  files.each do |file|
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, *RUBY_WARNING_FLAGS, *STRICT_BLOCK_WARNING_FLAGS, '-c', file)
    next if status.success? && stderr.empty?
    warn stdout unless status.success?
    warn stderr unless stderr.empty?
    abort "Ruby syntax/warning check failed: #{file}"
  end
  puts "Syntax and warnings checked: #{files.length} project files"
end

desc 'Check adapter method visibility with Jeremy Evans\' visibility_checker'
task :check_visibility do
  ruby(*RUBY_WARNING_FLAGS, *STRICT_BLOCK_WARNING_FLAGS, '-Ilib', 'tasks/check_visibility.rb')
end

desc 'Run Sequel upstream SQLite and integration specs (requires tmp/upstream/sequel)'
task :upstream do
  ruby(*RUBY_WARNING_FLAGS, *STRICT_BLOCK_WARNING_FLAGS, 'test/upstream.rb')
end

desc 'Run opt-in HTTP/Turso tests using LIBSQL_TEST_URL and LIBSQL_TEST_AUTH_TOKEN'
task :remote do
  ruby(*RUBY_WARNING_FLAGS, *STRICT_BLOCK_WARNING_FLAGS, '-Ilib', 'test/remote.rb')
end

desc 'Run the native HTTP tests against the local upstream Hrana fixture'
task :remote_local do
  sh({'LIBSQL_TEST_URL' => 'http://localhost:8080', 'LIBSQL_TEST_AUTH_TOKEN' => ''},
    'tmp/hrana-venv/bin/python', 'test/support/hrana_server.py',
    RbConfig.ruby, *RUBY_WARNING_FLAGS, *STRICT_BLOCK_WARNING_FLAGS, '-Ilib', 'test/remote.rb')
end
