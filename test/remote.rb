# frozen-string-literal: true

# Opt-in: creates and drops only a randomly named test table in the supplied DB.
require_relative 'test_helper'
require 'securerandom'

class RemoteTest < Minitest::Test
  def setup
    @db = Sequel.connect(:adapter => :libsql,
      :database => ENV.fetch('LIBSQL_TEST_URL'),
      :auth_token => ENV['LIBSQL_TEST_AUTH_TOKEN'], :max_connections => 2)
    @table = :"sequel_test_#{SecureRandom.hex(8)}"
    @db.create_table(@table) do
      primary_key :id
      String :name, :unique => true, :null => false
      Integer :quantity
      File :data
    end
    @created = true
    @items = @db[@table]
  end

  def teardown
    @db.drop_table(@table) if @created
  ensure
    @db.disconnect if @db
  end

  def test_native_remote_crud_and_bindings
    bytes = Sequel.blob("\0\xFFhi\0".b)
    assert_equal 1, @items.call(:insert, {:name => '世界 😀', :quantity => -4, :data => bytes},
      :name => :$name, :quantity => :$quantity, :data => :$data)
    assert_equal({:id => 1, :name => '世界 😀', :quantity => -4, :data => bytes}, @items.first)
    assert_equal 1, @items.where(:id => :$id).call(:update, {:id => 1, :n => 7}, :quantity => :$n)
    assert_equal 7, @items.get(:quantity)
    assert_raises(Sequel::UniqueConstraintViolation){@items.insert(:name => '世界 😀')}
    assert_equal 1, @items.delete
  end

  def test_native_remote_transaction_stream
    @db.transaction do
      @items.insert(:name => 'kept')
      @db.transaction(:savepoint => true) do
        @items.insert(:name => 'discarded')
        raise Sequel::Rollback
      end
      assert_equal ['kept'], @items.select_map(:name)
    end
    @db.transaction do
      @items.insert(:name => 'rolled back')
      raise Sequel::Rollback
    end
    assert_equal ['kept'], @items.select_map(:name)
    @db.disconnect
    assert_equal ['kept'], @items.select_map(:name)
  end

  def test_native_remote_returning_and_schema
    assert_equal [{:id => 1}], @items.returning(:id).insert(:name => 'one')
    assert_equal :blob, @db.schema(@table).to_h[:data][:type]
    assert @db.indexes(@table).values.any?{|index| index[:unique]}
  end
end
