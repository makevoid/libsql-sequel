# frozen-string-literal: true

require_relative 'test_helper'

class ValuesTest < AdapterTest
  def bound(value)
    @db.select(Sequel.as(:$value, :value)).call(:first, :value => value)[:value]
  end

  def test_runtime_values
    [nil, 0, -1, -(1 << 63), (1 << 63) - 1, 1.25, '', 'héllø 世界 😀', "quotes ' \" \\"].each do |value|
      actual = bound(value)
      value.nil? ? assert_nil(actual) : assert_equal(value, actual)
    end
    assert_equal Encoding::UTF_8, bound('世界').encoding
  end

  def test_binary_data_and_empty_blobs
    ["\0\xFFabc\0".b, ''.b, (0..255).to_a.pack('C*')].each do |bytes|
      result = bound(Sequel.blob(bytes))
      assert_instance_of Sequel::SQL::Blob, result
      assert_equal bytes, result
      assert_equal Encoding::BINARY, result.encoding
    end
  end

  def test_invalid_inputs_fail_before_native_truncation
    assert_raises(Sequel::Error){bound(1 << 63)}
    assert_raises(Sequel::Error){bound(-(1 << 63) - 1)}
    assert_raises(Sequel::Error){bound(Float::INFINITY)}
    assert_raises(Sequel::Error){bound(Float::NAN)}
    assert_raises(Sequel::Error){bound("has\0nul")}
    assert_raises(Sequel::Error){@db.get("has\0nul")}
    assert_raises(Sequel::Error){bound(Object.new)}
    assert_equal 'still works', bound('still works')
  end

  def test_invalid_text_encodings_raise_sequel_errors
    ["\xFF".b, "\xFF".dup.force_encoding(Encoding::UTF_8),
     "\x00".dup.force_encoding(Encoding::UTF_16LE)].each do |value|
      assert_raises(Sequel::Error){bound(value)}
      assert_raises(Sequel::Error){@db.get(value)}
    end
    assert_equal 'still works', bound('still works')
    assert_equal "\xFF".b, bound(Sequel.blob("\xFF".b))
  end

  def test_text_is_transcoded_to_utf8
    value = "caf\xE9".dup.force_encoding(Encoding::ISO_8859_1)
    assert_equal 'café', bound(value)
    assert_equal 'café', @db.get(value)
    assert_equal Encoding::UTF_8, bound(value).encoding
  end

  def test_dates_times_decimals_and_booleans
    @db.create_table(:typed) do
      Date :day
      DateTime :moment
      Time :clock, :only_time => true
      BigDecimal :amount, :size => [10, 2]
      TrueClass :active
    end
    values = {:day => Date.new(2026, 10, 31), :moment => Time.local(2026, 10, 31, 12, 30, 15),
              :clock => Sequel::SQLTime.create(12, 30, 15), :amount => BigDecimal('123.45'), :active => false}
    @db[:typed].call(:insert, values, values.to_h{|key, _| [key, :"$#{key}"]})
    row = @db[:typed].first
    assert_equal values, row
  end

  def test_string_boolean_mode
    @db.integer_booleans = false
    items = create_items
    items.call(:insert, {:name => 'false', :active => false}, :name => :$name, :active => :$active)
    assert_equal false, items.first[:active]
    assert_equal 'f', @db.fetch('SELECT active FROM items').first[:active]
  end

  def test_named_driver_arguments
    @db.execute('SELECT :name AS name, :n AS n', :arguments => {:name => '世界', :n => -5}) do |result|
      assert_equal ['name', 'n'], result.columns
      result.each{|values| assert_equal ['世界', -5], values}
    end
  end

  def test_early_break_and_consumer_exception_free_current_row
    items = create_items
    3.times{|i| items.insert(:name => i.to_s)}
    original = CLibsql.method(:libsql_row_deinit)
    freed = 0
    release = proc{|row| freed += 1; original.call(row)}
    @db.schema(:items)
    CLibsql.stub(:libsql_row_deinit, release) do
      items.each{break}
      assert_equal 1, freed
      assert_raises(RuntimeError){items.each{raise 'consumer failed'}}
      assert_equal 2, freed
    end
    @db.drop_table(:items)
    assert_equal 7, @db.get(7)
  end

  def test_result_cannot_be_used_after_its_query_block
    result = nil
    @db.execute('SELECT 1'){|rows| result = rows}
    assert_raises(Sequel::LibSQL::Native::Error){result.each{|row| row}}
    assert_raises(Sequel::LibSQL::Native::Error){result.columns}
    result.close
  end

  def test_native_resources_are_released_on_query_and_bind_errors
    @db.sqlite_version
    [:libsql_statement_deinit, :libsql_rows_deinit].each do |method|
      original = CLibsql.method(method)
      released = 0
      CLibsql.stub(method, proc{|value| released += 1; original.call(value)}) do
        assert_raises(RuntimeError){@db.fetch('SELECT 1').each{raise 'consumer failure'}}
        assert_equal 1, released
      end
    end
    original = CLibsql.method(:libsql_statement_deinit)
    released = 0
    CLibsql.stub(:libsql_statement_deinit, proc{|value| released += 1; original.call(value)}) do
      assert_raises(Sequel::Error){bound(Object.new)}
      assert_equal 1, released
    end
  end

  def test_type_hints_for_joins_and_nulls
    @db.create_table(:flags){Integer :id; TrueClass :active}
    @db[:flags].insert(:id => 1, :active => true)
    joined = @db.from(Sequel.as(:flags, :a)).join(Sequel.as(:flags, :b), :id => :id).
      select(Sequel[:a][:active].as(:enabled))
    assert_equal 1, joined.first[:enabled]
    assert_equal true, joined.with_libsql_types(:enabled => :boolean).first[:enabled]
    assert_nil @db.select(Sequel.as(nil, :enabled)).with_libsql_types(:enabled => :boolean).first[:enabled]
    assert_equal 'ONE', @db.select(Sequel.as('one', :name)).with_libsql_types(:name => proc{|v| v.upcase}).first[:name]
  end

  def test_identifier_aliases_and_prepared_projections
    items = create_items
    items.insert(:name => 'one', :active => true)
    dataset = items.select(Sequel[:items][Sequel.identifier(:active)].as(Sequel.identifier(:enabled)))
    assert_equal true, dataset.first[:enabled]
    assert_equal true, dataset.where(:id => :$id).call(:first, :id => 1)[:enabled]
    assert_equal true, items.returning(:active).where(:id => :$id).call(:update, {:id => 1}, :active => true).first[:active]
  end

  def test_wildcards_and_duplicate_output_names_do_not_guess_expression_types
    items = create_items
    items.insert(:name => 'one', :active => true)
    assert_equal true, items.select_all(:items).select_append(Sequel.as(123, :extra)).first[:active]
    assert_equal 'raw', items.select(:active, Sequel.as('raw', :active)).first[:active]
    assert_equal 'raw', items.select_all(:items).select_append(Sequel.as('raw', :active)).first[:active]
  end

  def test_repeated_get_keeps_column_types_without_typing_expressions
    items = create_items
    items.insert(:name => 'one', :active => true)
    5.times do
      assert_equal true, items.get(:active)
      assert_equal 'raw', items.get(Sequel.as('raw', :active))
    end
  end
end
