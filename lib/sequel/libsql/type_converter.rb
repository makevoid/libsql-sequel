# frozen-string-literal: true

module Sequel
  module LibSQL
    # Apply SQLite's semantic types after decoding the native storage value.
    class TypeConverter
      FALSE_VALUES = [0, '0', 'false', 'f', 'no', 'n'].freeze

      def initialize(database)
        @database = database
      end

      def call(value, type)
        return nil if value.nil?
        return type.call(value) if type.respond_to?(:call)
        case type
        when :boolean
          !FALSE_VALUES.include?(value.is_a?(String) ? value.downcase : value)
        when :date
          value.is_a?(Numeric) ? Date.jd(value.to_i) : Sequel.string_to_date(value)
        when :datetime, :timestamp
          @database.to_application_timestamp(value)
        when :time
          time(value)
        when :decimal
          decimal(value)
        when :integer
          value.to_i
        when :float
          value.to_f
        when :blob
          Sequel.blob(value.to_s)
        else
          value
        end
      end

      private

      def time(value)
        return Sequel.string_to_time(value) if value.is_a?(String)
        seconds, fraction = value.divmod(1)
        SQLTime.create(seconds / 3600, (seconds % 3600) / 60, seconds % 60, (fraction * 1_000_000).round)
      end

      def decimal(value)
        BigDecimal(value.to_s)
      rescue ArgumentError
        value.to_s
      end
    end
  end
end
