# frozen-string-literal: true

require_relative 'test_helper'

class ForkTest < AdapterTest
  def test_child_disconnect_discards_inherited_handles_without_native_cleanup
    skip 'fork is unavailable' unless Process.respond_to?(:fork)
    connection = @db.synchronize{|conn| conn}
    assert_equal 123, @db.get(123)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      begin
        reject_cleanup = proc{|_| raise 'native destructor called in child'}
        CLibsql.stub(:libsql_connection_deinit, reject_cleanup) do
          CLibsql.stub(:libsql_database_deinit, reject_cleanup) do
            assert_raises(Sequel::Error){connection.execute('SELECT 1')}
            2.times{@db.disconnect}
            assert_equal 0, @db.pool.size
            assert_nil connection.close
            assert_raises(Sequel::Error){connection.execute('SELECT 1')}
          end
        end
        writer.write('ok')
      rescue Exception => e
        writer.write("#{e.class}: #{e.message}")
      ensure
        writer.close
        exit! 0
      end
    end
    writer.close
    assert IO.select([reader], nil, nil, 10), 'child disconnect timed out'
    assert_equal 'ok', reader.read
    Process.wait(pid)
    pid = nil
    assert_equal 1, @db.pool.size
    assert_equal 123, @db.get(123)
  ensure
    reader.close if reader && !reader.closed?
    writer.close if writer && !writer.closed?
    if pid
      Process.kill('KILL', pid)
      Process.wait(pid)
    end
  end
end
