# frozen-string-literal: true

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

      def fetch_rows(sql)
        execute(sql) do |result|
          types = libsql_types
          columns = result.columns.map{|column| output_identifier(column)}
          # A name shared by multiple result columns has no unique origin.
          # Explicit hints still apply to that name at the caller's request.
          duplicates = columns.tally.select{|_, count| count > 1}.keys
          types = types.reject{|name, _| duplicates.include?(name)}.merge(@opts[:libsql_types] || OPTS) unless duplicates.empty?
          self.columns = columns
          result.each do |values|
            row = {}
            columns.each_with_index do |name, index|
              value = values[index]
              row[name] = value.nil? ? nil : convert_libsql_value(value, types[name])
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

      # C exposes no decltypes. Only infer types where the selected expression
      # has a known table-column origin; never guess from an expression's alias.
      def libsql_types
        explicit = @opts[:libsql_types] || OPTS
        return @opts[:orig_dataset].send(:libsql_types).merge(explicit) if @opts[:orig_dataset]
        return explicit if @opts[:sql] || @opts[:join] || @opts[:with] || @opts[:compounds]
        sources = @opts[:from]
        return explicit unless sources && sources.length == 1
        source = sources.first
        source = source.expression if source.is_a?(SQL::AliasedExpression)
        return explicit unless source.is_a?(Symbol) || source.is_a?(String) || source.is_a?(SQL::Identifier) || source.is_a?(SQL::QualifiedIdentifier)

        selection = @opts[:returning] || @opts[:select]
        if selection && !selection.empty? && selection.none?{|column| libsql_column?(column)}
          return explicit
        end
        schema = db.schema(source).to_h
        types = {}
        if !selection || selection.empty? || selection.all?{|column| column.is_a?(SQL::ColumnAll)}
          schema.each{|name, info| types[name] = info[:type]}
        else
          selection.each do |column|
            if column.is_a?(SQL::ColumnAll)
              schema.each{|name, info| types[name] = info[:type]}
              next
            end
            aliaz = nil
            if column.is_a?(SQL::AliasedExpression)
              aliaz = column.alias
              column = column.expression
            end
            name = case column
            when Symbol
              _, name, symbol_alias = split_symbol(column)
              aliaz ||= symbol_alias
              name
            when SQL::Identifier
              column.value
            when SQL::QualifiedIdentifier
              column.column
            end
            name = name.value if name.is_a?(SQL::Identifier)
            aliaz = aliaz.value if aliaz.is_a?(SQL::Identifier)
            if name && (info = schema[output_identifier(name)])
              types[output_identifier(aliaz || name)] = info[:type]
            elsif aliaz
              types.delete(output_identifier(aliaz))
            end
          end
        end
        types.merge(explicit)
      end

      def libsql_column?(column)
        column = column.expression if column.is_a?(SQL::AliasedExpression)
        column.is_a?(Symbol) || column.is_a?(SQL::Identifier) || column.is_a?(SQL::QualifiedIdentifier) || column.is_a?(SQL::ColumnAll)
      end

      def convert_libsql_value(value, type)
        return type.call(value) if type.respond_to?(:call)
        case type
        when :boolean
          ![0, '0', 'false', 'f', 'no', 'n'].include?(value.is_a?(String) ? value.downcase : value)
        when :date
          value.is_a?(Numeric) ? Date.jd(value.to_i) : Sequel.string_to_date(value)
        when :datetime, :timestamp
          db.to_application_timestamp(value)
        when :time
          value.is_a?(String) ? Sequel.string_to_time(value) : SQLTime.create(value.to_i / 3600, (value.to_i % 3600) / 60, value % 60)
        when :decimal
          BigDecimal(value.to_s)
        when :blob
          Sequel.blob(value)
        else
          value
        end
      end
    end
  end
end
