# frozen-string-literal: true

require_relative 'native'

module Sequel
  module LibSQL
    # Owns a native database and its connection for one Sequel pool slot.
    class Connection
      def initialize(options)
        @pid = Process.pid
        @replica = options[:path] && options[:url]
        desc = CLibsql::DatabaseDesc.new
        @strings = []
        [:path, :url, :auth_token, :encryption_key, :namespace].each do |key|
          next if options[key].nil?
          desc[key] = pointer = FFI::MemoryPointer.from_string(Native.string(options[key]))
          @strings << pointer
        end
        desc[:sync_interval] = options.fetch(:sync_interval, 0)
        desc[:disable_read_your_writes] = !options.fetch(:read_your_writes, true)
        @database = Native.check(Native.database_init(desc))
        begin
          @connection = Native.check(Native.database_connect(@database))
        rescue Exception
          close
          raise
        end
      end

      def execute(sql, arguments = [])
        with_statement(sql, arguments) do |statement|
          Native.check(Native.statement_execute(statement))[:rows_changed]
        end
      end

      def execute_batch(sql)
        check_open
        Native.check(Native.connection_batch(@connection, Native.string(sql)))
        nil
      end

      def query(sql, arguments = [])
        with_statement(sql, arguments) do |statement|
          result = Result.new(Native.check(Native.statement_query(statement)))
          begin
            yield result
          ensure
            result.close
          end
        end
      end

      def last_insert_id
        check_open
        Native.check(Native.connection_info(@connection))[:last_inserted_id]
      end

      def sync
        check_open
        raise Sequel::Error, 'sync requires an embedded replica (both path and remote URL)' unless @replica
        result = Native.check(Native.database_sync(@database))
        {:frame_no => result[:frame_no], :frames_synced => result[:frames_synced]}
      end

      def close
        # Inherited handles belong to the parent; their runtime cannot be used
        # or destroyed in the child. Let Sequel empty the child's pool safely.
        if @pid != Process.pid
          @connection = @database = @strings = nil
          return
        end
        if @connection
          CLibsql.libsql_connection_deinit(@connection)
          @connection = nil
        end
        if @database
          CLibsql.libsql_database_deinit(@database)
          @database = nil
        end
        @strings = nil
        nil
      end

      private

      def check_process
        raise Sequel::Error, 'libSQL connections cannot be used after fork; connect inside each worker' unless @pid == Process.pid
      end

      def check_open
        check_process
        raise Native::Error, 'libSQL connection is closed' unless @connection
      end

      def with_statement(sql, arguments)
        check_open
        statement = Native.check(Native.connection_prepare(@connection, Native.string(sql)))
        begin
          case arguments
          when Array
            arguments.each do |value|
              Native.bind_value(value){|v| Native.check(CLibsql.libsql_statement_bind_value(statement, v))}
            end
          when Hash
            arguments.each do |name, value|
              name = Native.string(name)
              name = ":#{name}" unless /\A[:@$]/.match?(name)
              Native.bind_value(value){|v| Native.check(CLibsql.libsql_statement_bind_named(statement, name, v))}
            end
          else
            raise Sequel::Error, 'libSQL arguments must be an Array or Hash'
          end
          yield statement
        ensure
          CLibsql.libsql_statement_deinit(statement)
        end
      end
    end

    # Only lives inside Connection#query; rows are freed even on break or raise.
    class Result
      def initialize(rows)
        @rows = rows
      end

      def columns
        check_open
        @columns ||= Array.new(Native.rows_column_count(@rows)) do |index|
          Native.read_slice(CLibsql.libsql_rows_column_name(@rows, index), true)
        end
      end

      def each
        check_open
        loop do
          check_open
          row = Native.check(Native.rows_next(@rows))
          break if row[:inner].null?
          begin
            values = Array.new(columns.length) do |index|
              Native.value(Native.check(CLibsql.libsql_row_value(row, index))[:ok])
            end
            yield values
          ensure
            CLibsql.libsql_row_deinit(row)
          end
        end
      end

      def close
        if @rows
          CLibsql.libsql_rows_deinit(@rows)
          @rows = nil
        end
        nil
      end

      private

      def check_open
        raise Native::Error, 'libSQL result is closed' unless @rows
      end
    end
  end
end
