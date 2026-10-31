# frozen-string-literal: true

# Run the unmodified upstream SQLite adapter and integration specs.
root = File.expand_path('..', __dir__)
upstream = File.join(root, 'tmp/upstream/sequel')
$LOAD_PATH.unshift(File.join(root, 'lib'), File.join(upstream, 'lib'))
require 'libsql-sequel'
DB = Sequel.connect(:adapter => :libsql)
Dir.chdir(upstream)
require File.join(upstream, 'spec/adapters/sqlite_spec')
Dir['spec/integration/*_test.rb'].each{|file| require File.expand_path(file)}
