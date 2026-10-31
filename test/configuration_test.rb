# frozen-string-literal: true

require_relative 'test_helper'

class ConfigurationTest < AdapterTest
  def configuration(options)
    Sequel::LibSQL::Configuration.new(@db, options)
  end

  def test_connection_modes_and_read_your_writes
    assert_equal ':memory:', configuration({}).native_options[:path]
    assert configuration({}).single_connection?
    remote = configuration(:database => 'libsql://example.turso.io', :auth_token => 'test-only')
    assert_nil remote.native_options[:path]
    refute remote.single_connection?
    replica = configuration(:url => 'libsql://example.turso.io', :database => 'local.db')
    assert replica.replica?
    assert replica.single_connection?
    assert_equal true, replica.native_options[:read_your_writes]
    assert_equal false, configuration(:read_your_writes => false).native_options[:read_your_writes]
    assert_equal false, configuration(:read_your_writes => 'false').native_options[:read_your_writes]
    assert_equal 1, @db.pool.max_size
  end

  def test_invalid_configuration
    [
      {:max_connections => 2}, {:auth_token => 'token'}, {:url => 'ftp://example.com'},
      {:url => 'https://user:password@example.com'}, {:url => 'libsql://example.com?auth_token=token'},
      {:database => 'local.db', :path => 'other.db'}, {:sync_interval => -1}, {:sync_interval => 100},
      {:url => 'libsql://example.com', :path => ':memory:'}, {:readonly => true}, {:setup_regexp_function => true}
    ].each do |options|
      assert_raises(Sequel::Error){configuration(options)}
    end
    assert_raises(Sequel::Error){@db.sync}
  end

  def test_file_database_reconnect_and_multiple_connections
    Dir.mktmpdir('libsql-sequel') do |dir|
      db = Sequel.connect(:adapter => :libsql, :database => File.join(dir, 'test.db'), :max_connections => 3)
      begin
        db.create_table(:items){primary_key :id; String :name}
        db[:items].insert(:name => 'persisted')
        db.disconnect
        assert_equal 'persisted', db[:items].get(:name)
        ready = Queue.new
        release = Queue.new
        threads = 3.times.map do
          Thread.new do
            db.synchronize do |connection|
              ready << connection.object_id
              release.pop
              db[:items].count
            end
          end
        end
        ids = 3.times.map{ready.pop}
        3.times{release << true}
        assert_equal 3, ids.uniq.size
        assert_equal [1, 1, 1], threads.map(&:value)
      ensure
        db.disconnect
      end
    end
  end

  def test_uri_is_a_remote_url
    db = Sequel.connect('libsql://example.turso.io', :test => false, :auth_token => 'test-only')
    assert_equal 'libsql://example.turso.io', db.opts[:database]
    assert_nil configuration(db.opts).native_options[:path]
  ensure
    db.disconnect if db
  end

  def test_turso_urls_use_https_without_becoming_local_files
    remote = configuration(:database => 'turso://example.turso.io', :auth_token => 'test-only')
    assert_equal 'https://example.turso.io', remote.native_options[:url]
    assert_nil remote.native_options[:path]
    assert remote.remote?
    replica = configuration(:url => 'turso://example.turso.io', :path => 'replica.db')
    assert replica.replica?
    assert_equal 'https://example.turso.io', replica.native_options[:url]
    assert_raises(Sequel::Error){configuration(:database => 'turso://user:secret@example.com')}
    assert_raises(Sequel::Error){configuration(:database => 'turso://example.com?auth_token=secret')}
    assert_raises(Sequel::Error){configuration(:database => 'turso://example.com#secret')}
  end

  def test_turso_uri_selects_the_libsql_adapter
    db = Sequel.connect('turso://example.turso.io', :test => false, :auth_token => 'test-only')
    assert_instance_of Sequel::LibSQL::Database, db
    assert_equal 'https://example.turso.io', configuration(db.opts).native_options[:url]
  ensure
    db.disconnect if db
  end

  def test_remote_local_only_options_are_rejected
    [:timeout, :case_sensitive_like, :synchronous, :temp_store, :auto_vacuum].each do |option|
      assert_raises(Sequel::Error){configuration(:url => 'libsql://example.com', option => 1)}
    end
    assert_raises(Sequel::Error){configuration(:path => '')}
    assert_raises(Sequel::Error){configuration(:database => ':memory:', :max_connections => 3)}
  end

  def test_no_auth_debug_logging_in_native_library
    # These markers exist in all of 0.2.1's bundled binaries. Keep credentials
    # out of the test: inspect only the bundled code's static debug string.
    binary = File.binread(CLibsql.ffi_libraries.first.name)
    refute binary.include?('(path, url, auth_token, encryption_key)')
    assert_equal Gem::Version.new('0.2.0'), Gem.loaded_specs.fetch('turso_libsql').version
  end

  def test_validation_freeze_and_idempotent_disconnect
    connection = @db.synchronize{|conn| conn}
    assert @db.valid_connection?(connection)
    @db.freeze
    assert_equal 123, @db.get(123)
    @db.disconnect
    refute @db.valid_connection?(connection)
    2.times{@db.disconnect_connection(connection)}
  end

  def test_initialization_failure_frees_both_native_handles
    released = []
    close_connection = CLibsql.method(:libsql_connection_deinit)
    close_database = CLibsql.method(:libsql_database_deinit)
    CLibsql.stub(:libsql_connection_deinit, proc{|value| released << :connection; close_connection.call(value)}) do
      CLibsql.stub(:libsql_database_deinit, proc{|value| released << :database; close_database.call(value)}) do
        assert_raises(Sequel::DatabaseConnectionError){Sequel.connect(:adapter => :libsql, :timeout => -1)}
      end
    end
    assert_equal [:connection, :database], released
  end
end
