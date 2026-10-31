# frozen-string-literal: true

require_relative 'result_types'
require_relative 'type_converter'

module Sequel
  module LibSQL
    class Dataset < Sequel::Dataset
      include Sequel::SQLite::DatasetMethods

      BindArgumentMethods = prepared_statements_module(:bind, Sequel::Dataset::UnnumberedArgumentMapper)
      PreparedStatementMethods = prepared_statements_module(:prepare, BindArgumentMethods)

      # Explicit conversions for raw SQL, expressions, or ambiguous projections.
      # DB.fetch(sql).with_libsql_types(:active=>:boolean, :created_at=>:datetime)
      def with_libsql_types(types)
        clone(:libsql_types => (@opts[:libsql_types] || OPTS).merge(types).freeze)
      end

      # Cached literalizers replace selected columns with opaque arguments.
      # Without C decltypes, keep the projection AST for stable conversions.
      def supports_placeholder_literalizer?
        false
      end

      def fetch_rows(sql)
        execute(sql) do |result|
          columns = result.columns.map{|column| output_identifier(column)}
          types = ResultTypes.new(self).for_columns(columns)
          column_types = columns.map{|name| types[name]}
          column_count = columns.length
          converter = TypeConverter.new(db)
          self.columns = columns
          result.each do |values|
            row = {}
            index = 0
            while index < column_count
              value = values[index]
              type = column_types[index]
              row[columns[index]] = type ? converter.call(value, type) : value
              index += 1
            end
            yield row
          end
        end
      end

      private

      def bound_variable_modules
        [BindArgumentMethods]
      end

      def prepared_statement_modules
        [PreparedStatementMethods]
      end

      def literal_string_append(sql, value)
        sql << "'" << Native.string(value).gsub("'", "''") << "'"
      end
    end
  end
end
