# frozen-string-literal: true

require 'libsql-sequel'

Sequel.connect(:adapter => :libsql) do |db|
  db.create_table(:items) do
    primary_key :id
    String :name, :null => false
    TrueClass :active, :default => true
  end

  items = db[:items]
  id = items.insert(:name => 'Hello, libSQL')
  find = items.where(:id => :$id).prepare(:first, :find_item)
  p find.call(:id => id)

  db.transaction(:rollback => :always){items.insert(:name => 'discarded')}
  puts "#{items.count} persisted item"
end
