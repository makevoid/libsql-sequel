# frozen-string-literal: true

gem 'turso_libsql', '= 0.2.0'
require 'libsql'

module Sequel
  module LibSQL
    # Private compatibility boundary for turso_libsql 0.2.x. Its high-level
    # wrappers have unsafe error handling and incorrect value conversions.
    # Reuse its ABI structs and library, without changing global driver classes.
    module Native
      class Error < StandardError; end

      extend FFI::Library
      ffi_lib(*CLibsql.ffi_libraries.map(&:name))

      {
        :database_init => [[CLibsql::DatabaseDesc.by_value], CLibsql::Database.by_value],
        :database_connect => [[CLibsql::Database.by_value], CLibsql::Connection.by_value],
        :database_sync => [[CLibsql::Database.by_value], CLibsql::Sync.by_value],
        :connection_prepare => [[CLibsql::Connection.by_value, :string], CLibsql::Statement.by_value],
        :connection_info => [[CLibsql::Connection.by_value], CLibsql::ConnectionInfo.by_value],
        :connection_batch => [[CLibsql::Connection.by_value, :string], CLibsql::Batch.by_value],
        :statement_execute => [[CLibsql::Statement.by_value], CLibsql::Execute.by_value],
        :statement_query => [[CLibsql::Statement.by_value], CLibsql::Rows.by_value],
        :rows_next => [[CLibsql::Rows.by_value], CLibsql::Row.by_value]
      }.each do |name, (args, result)|
        attach_function name, :"libsql_#{name}", args, result, :blocking => true
      end

      # The upstream declaration incorrectly uses Row.by_value for this call.
      attach_function :slice_deinit, :libsql_slice_deinit, [CLibsql::Slice.by_value], :void

      # The released gem and upstream main use different names for this symbol.
      count_function = CLibsql.respond_to?(:libsql_rows_column_count) ? :libsql_rows_column_count : :libsql_rows_column_length
      attach_function :rows_column_count, count_function, [CLibsql::Rows.by_value], :int32

      def self.check(result)
        return result if result[:err].null?

        begin
          message = CLibsql.libsql_error_message(result[:err])
        ensure
          CLibsql.libsql_error_deinit(result[:err])
        end
        raise Error, message
      end

      def self.string(value)
        value = value.to_s.encode(Encoding::UTF_8)
        raise Sequel::Error, 'libSQL text cannot contain NUL bytes; use Sequel.blob for binary data' if value.include?("\0")
        raise Sequel::Error, 'libSQL text must be valid UTF-8' unless value.valid_encoding?
        value
      rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
        raise Sequel::Error, 'libSQL text must be convertible to UTF-8; use Sequel.blob for binary data'
      end

      # C text slices include a terminal NUL; blob slices do not.
      def self.read_slice(slice, text)
        return text ? '' : Sequel.blob('') if slice[:ptr].null?

        begin
          length = slice[:len]
          value = slice[:ptr].read_string_length(text ? [length - 1, 0].max : length)
          text ? value.force_encoding(Encoding::UTF_8) : Sequel.blob(value)
        ensure
          slice_deinit(slice)
        end
      end

      def self.value(value)
        case value[:type]
        when :null
          nil
        when :integer
          # The Ruby driver declares uint64, while the C API returns int64.
          integer = value[:value][:integer]
          integer >= (1 << 63) ? integer - (1 << 64) : integer
        when :real
          value[:value][:real]
        when :text, :blob
          read_slice(value[:value][value[:type]], value[:type] == :text)
        else
          raise Error, 'unknown libSQL value type'
        end
      end

      # Keep the input pointer alive until the native bind has copied its bytes.
      def self.bind_value(value)
        case value
        when nil
          yield CLibsql.libsql_null
        when Integer
          unless (-(1 << 63)...(1 << 63)).cover?(value)
            raise Sequel::Error, 'libSQL integers must fit in signed 64 bits'
          end
          yield CLibsql.libsql_integer(value)
        when Float
          raise Sequel::Error, 'libSQL cannot bind non-finite floats' unless value.finite?
          yield CLibsql.libsql_real(value)
        when SQL::Blob
          pointer = FFI::MemoryPointer.new(:char, [value.bytesize, 1].max)
          pointer.put_bytes(0, value)
          yield CLibsql.libsql_blob(pointer, value.bytesize)
        when String
          value = string(value)
          pointer = FFI::MemoryPointer.from_string(value)
          yield CLibsql.libsql_text(pointer, value.bytesize)
        else
          raise Sequel::Error, "unsupported libSQL bound value type: #{value.class}"
        end
      end
    end
  end
end
