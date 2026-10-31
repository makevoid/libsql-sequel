# frozen-string-literal: true

require_relative 'test_helper'

# Equivalent cases from Sequel's SQLite type-conversion group. Upstream gates
# that entire group on adapter_scheme == :sqlite, excluding external adapters.
class SQLiteTypesTest < AdapterTest
  def typed_column(type, options = {})
    @db.create_table(:typed_values){column :value, type, options}
    @db[:typed_values]
  end

  def test_boolean_storage_values_and_expressions
    values = typed_column(TrueClass)
    [false, true].each do |value|
      values.delete
      values.insert(:value => value)
      assert_equal value, values.get(:value)
      assert_equal(value ? 2 : 0, values.get(Sequel[:value] + Sequel[:value]))
    end
  end

  def test_numeric_storage_classes_and_nonnumeric_values
    values = typed_column(Numeric)
    [100, 100.1, '100.1', BigDecimal('100.1')].each do |value|
      values.delete
      values.insert(:value => value)
      assert_equal BigDecimal(value.to_s), values.get(:value)
      assert_instance_of BigDecimal, values.get(:value)
    end
    values.update(:value => 'not a number')
    assert_equal 'not a number', values.get(:value)
  end

  def test_numeric_dates_are_julian_days
    values = typed_column(Date)
    [2455979, 2455979.1].each do |value|
      values.delete
      values.insert(:value => value)
      assert_equal Date.jd(2455979), values.get(:value)
    end
  end

  def test_numeric_times_preserve_fractional_seconds
    values = typed_column(Time, :only_time => true)
    values.insert(:value => 3661)
    assert_equal Sequel::SQLTime.create(1, 1, 1), values.get(:value)
    values.update(:value => 3661.000001)
    assert_equal Sequel::SQLTime.create(1, 1, 1, 1), values.get(:value)
  end

  def test_integer_timestamps_are_unix_seconds_for_both_datetime_classes
    values = typed_column(DateTime)
    seconds = 1329860756
    values.insert(:value => seconds)
    assert_equal Time.at(seconds), values.get(:value)
    previous = Sequel.datetime_class
    begin
      Sequel.datetime_class = DateTime
      assert_equal DateTime.strptime(seconds.to_s, '%s'), values.get(:value)
    ensure
      Sequel.datetime_class = previous
    end
  end

  def test_float_timestamps_are_julian_days_for_both_datetime_classes
    values = typed_column(DateTime)
    values.insert(:value => 2455979.5)
    assert_equal Time.at(1329825600), values.get(:value)
    previous = Sequel.datetime_class
    begin
      Sequel.datetime_class = DateTime
      assert_equal DateTime.jd(2455979.5), values.get(:value)
    ensure
      Sequel.datetime_class = previous
    end
  end

  def test_blob_columns_accept_nonblob_storage_values
    values = typed_column(File)
    [1, 1.1, 'text'].each do |value|
      values.delete
      values.insert(:value => value)
      result = values.get(:value)
      assert_instance_of Sequel::SQL::Blob, result
      assert_equal value.to_s, result
    end
  end
end
