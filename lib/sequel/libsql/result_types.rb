# frozen-string-literal: true

module Sequel
  module LibSQL
    # Resolve only projections with a known table-column origin. C exposes no
    # declared types, so raw SQL and ambiguous result columns need explicit hints.
    class ResultTypes
      def initialize(dataset)
        @dataset = dataset
        @opts = dataset.opts
      end

      def for_columns(columns)
        types = inferred_types
        columns.tally.each{|name, count| types.delete(name) if count > 1}
        types.merge(@opts[:libsql_types] || OPTS)
      end

      private

      def inferred_types
        if original = @opts[:orig_dataset]
          return self.class.new(original).send(:inferred_types)
        end
        return {} unless table = source_table
        selection = @opts[:returning] || @opts[:select]
        return {} if selection && !selection.empty? && selection.none?{|column| column?(column)}

        schema = @dataset.db.schema(table).to_h
        return schema.transform_values{|info| info[:type]} if !selection || selection.empty?
        types = {}
        selection.each{|column| add_projection(types, schema, column)}
        types
      end

      def source_table
        return if [:sql, :join, :with, :compounds].any?{|key| @opts[key]}
        sources = @opts[:from]
        return unless sources && sources.length == 1
        source = sources.first
        source = source.expression if source.is_a?(SQL::AliasedExpression)
        source if identifier?(source) || source.is_a?(String)
      end

      def add_projection(types, schema, column)
        if column.is_a?(SQL::ColumnAll)
          return schema.each{|name, info| types[name] = info[:type]}
        end
        name, aliaz = column_names(column)
        if name && (info = schema[output_identifier(name)])
          types[output_identifier(aliaz || name)] = info[:type]
        elsif aliaz
          types.delete(output_identifier(aliaz))
        end
      end

      def column_names(column)
        aliaz = nil
        if column.is_a?(SQL::AliasedExpression)
          aliaz = column.alias
          column = column.expression
        end
        name = case column
        when Symbol
          _, name, symbol_alias = @dataset.send(:split_symbol, column)
          aliaz ||= symbol_alias
          name
        when SQL::Identifier
          column.value
        when SQL::QualifiedIdentifier
          column.column
        end
        [name, aliaz]
      end

      def column?(column)
        column = column.expression if column.is_a?(SQL::AliasedExpression)
        identifier?(column) || column.is_a?(SQL::ColumnAll)
      end

      def identifier?(value)
        value.is_a?(Symbol) || value.is_a?(SQL::Identifier) || value.is_a?(SQL::QualifiedIdentifier)
      end

      def output_identifier(value)
        value = value.value if value.is_a?(SQL::Identifier)
        @dataset.send(:output_identifier, value)
      end
    end
  end
end
