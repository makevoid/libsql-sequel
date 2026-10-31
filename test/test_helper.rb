# frozen-string-literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'stringio'
require 'logger'
require 'libsql-sequel'

class AdapterTest < Minitest::Test
  def setup
    @db = Sequel.connect(:adapter => :libsql)
  end

  def teardown
    @db.disconnect
  end

  def create_items
    @db.create_table(:items) do
      primary_key :id
      String :name, :null => false, :unique => true
      Integer :quantity, :default => 0
      TrueClass :active
    end
    @db[:items]
  end
end
