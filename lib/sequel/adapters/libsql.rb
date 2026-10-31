# frozen-string-literal: true

require 'sequel'
require 'sequel/adapters/shared/sqlite'
require_relative '../libsql/connection'
require_relative '../libsql/configuration'
require_relative '../libsql/dataset'

module Sequel
  module LibSQL
    class Database < Sequel::Database
      include Sequel::SQLite::DatabaseMethods

      set_adapter_scheme :libsql

      # libsql://host is a native remote URL. Use a hash for local files.
      def self.uri_to_options(uri)
        {:database => uri.to_s}
      end
      private_class_method :uri_to_options

      def connect(server)
        options = server_opts(server)
        configuration = Configuration.new(self, options)
        connection = Connection.new(configuration.native_options)
        begin
          pragmas = connection_pragmas
          if configuration.remote?
            # The native remote SQL parser rejects these local-only PRAGMAs.
            pragmas = pragmas.grep(/\APRAGMA foreign_keys = /)
          else
            timeout = Integer(options.fetch(:timeout, 5000))
            raise Sequel::Error, 'timeout must be a nonnegative 32-bit millisecond value' unless (0..2_147_483_647).cover?(timeout)
            pragmas += ["PRAGMA busy_timeout = #{timeout}"]
          end
          pragmas.each do |sql|
            log_connection_yield(sql, connection){connection.execute_batch(sql)}
          end
          connection
        rescue Exception
          connection.close
          raise
        end
      end

      def disconnect_connection(connection)
        connection.close
      end

      # Match SQLite's unix-second and Julian-day timestamp representations.
      def to_application_timestamp(value)
        case value
        when Integer
          super(Time.at(value).to_s)
        when Float
          super(DateTime.jd(value).to_s)
        else
          super
        end
      end

      def execute(sql, opts=OPTS, &block)
        _execute(:select, sql, opts, &block)
      end

      def execute_dui(sql, opts=OPTS)
        _execute(:update, sql, opts)
      end

      def execute_insert(sql, opts=OPTS)
        _execute(:insert, sql, opts)
      end

      # DB.run accepts SQL batches, as in Sequel's SQLite adapter.
      def execute_ddl(sql, opts=OPTS)
        synchronize(opts[:server]) do |connection|
          log_connection_yield(sql, connection){connection.execute_batch(sql)}
        end
      rescue Native::Error => e
        raise_error(e)
      end

      # Pull remote changes into an embedded replica. Writes use the native
      # read-your-writes setting (enabled by default).
      def sync(opts=OPTS)
        synchronize(opts[:server]) do |connection|
          raise Sequel::Error, 'cannot sync inside a transaction' if in_transaction?(:server => opts[:server])
          connection.sync
        end
      rescue Native::Error => e
        raise_error(e)
      end

      private

      def adapter_initialize
        set_integer_booleans
        self.transaction_mode = @opts[:transaction_mode].to_sym if @opts[:transaction_mode]
      end

      def connection_pool_default_options
        options = super.dup
        options[:max_connections] = 1 if Configuration.new(self, @opts).single_connection?
        options
      end

      def database_error_classes
        [Native::Error]
      end

      # Validation sends SELECT NULL, while transaction commands send no rows.
      # The native batch API handles both without leaking a result cursor.
      def connection_execute_method
        :execute_batch
      end

      def database_specific_error_class(exception, opts)
        case exception.message
        when /libSQL connection is closed|Hrana:.*stream closed/i
          DatabaseDisconnectError
        when /UNIQUE constraint failed|PRIMARY KEY must be unique/i
          UniqueConstraintViolation
        when /NOT NULL constraint failed/i
          NotNullConstraintViolation
        when /FOREIGN KEY constraint failed/i
          ForeignKeyConstraintViolation
        when /CHECK constraint failed/i
          CheckConstraintViolation
        when /cannot store \w+ value in \w+ column|constraint failed/i
          ConstraintViolation
        else
          super
        end
      end

      def dataset_class_default
        Dataset
      end

      def _execute(type, sql, opts)
        if sql.is_a?(Symbol)
          sql = prepared_statement(sql).prepared_sql
        end
        arguments = opts.fetch(:arguments, [])
        arguments = if arguments.is_a?(Hash)
          arguments.transform_values{|value| bound_value(value)}
        else
          arguments.map{|value| bound_value(value)}
        end
        synchronize(opts[:server]) do |connection|
          log_connection_yield(sql, connection, opts[:arguments]) do
            if type == :select && block_given?
              connection.query(sql, arguments){|result| yield result}
            else
              changed = connection.execute(sql, arguments)
              type == :insert ? connection.last_insert_id : changed
            end
          end
        end
      rescue Native::Error => e
        raise_error(e)
      end

      def bound_value(value)
        case value
        when Time, Date, DateTime
          literal(value)[1...-1]
        when BigDecimal
          value.to_s('F')
        when true, false
          integer_booleans ? (value ? 1 : 0) : (value ? 't' : 'f')
        else
          value
        end
      end
    end
  end
end
