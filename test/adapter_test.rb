# frozen-string-literal: true

require_relative 'test_helper'

class SequelAdapterTest < AdapterTest
  def test_crud_ids_and_affected_counts
    items = create_items
    assert_equal 1, items.insert(:name => 'one', :active => true)
    assert_equal 2, items.insert(:name => 'two', :active => false)
    assert_equal [true, false], items.order(:id).select_map(:active)
    assert_equal 1, items.where(:id => 1).update(:quantity => 3)
    assert_equal 0, items.where(:id => 100).update(:quantity => 3)
    assert_equal 2, items.delete
    assert_equal 0, items.count
  end

  def test_transactions_and_savepoints
    items = create_items
    @db.transaction do
      items.insert(:name => 'kept')
      @db.transaction(:savepoint => true) do
        items.insert(:name => 'discarded')
        raise Sequel::Rollback
      end
    end
    assert_equal ['kept'], items.select_map(:name)
    assert_raises(RuntimeError) do
      @db.transaction(:mode => :immediate) do
        items.insert(:name => 'failed')
        raise 'application failure'
      end
    end
    assert_equal ['kept'], items.select_map(:name)
    @db.transaction(:rollback => :always){items.insert(:name => 'rolled back')}
    assert_equal 1, items.count
  end

  def test_commit_failure_is_an_exception_and_connection_is_reusable
    @db.create_table(:parents){primary_key :id}
    @db.create_table(:children){foreign_key :parent_id, :parents, :deferrable => true}
    assert_raises(Sequel::ForeignKeyConstraintViolation) do
      @db.transaction{@db[:children].insert(:parent_id => 123)}
    end
    assert_equal 0, @db[:children].count
    assert_equal 1, @db.get(1)
  end

  def test_bound_variables_and_named_prepared_queries
    items = create_items
    insert = items.prepare(:insert, :insert_item, :name => :$name, :active => :$active)
    assert_equal 1, insert.call(:name => "' ; DROP TABLE items; -- 😀", :active => true)
    assert_equal 2, @db.call(:insert_item, :name => 'two', :active => false)
    find = items.where(:id => :$id).prepare(:first, :find_item)
    assert_equal true, find.call(:id => 1)[:active]
    assert_equal false, find.call(:id => 2)[:active]
    assert_nil find.call(:id => 3)
    assert_equal 1, items.where(:id => :$id).call(:update, {:id => 2, :n => 9}, :quantity => :$n)
    assert_equal 9, items.where(:id => 2).get(:quantity)
    assert_equal 1, items.where(:id => :$id).call(:delete, :id => 2)
    assert_equal 1, items.count
  end

  def test_repeated_placeholders_and_replaced_prepared_queries
    items = create_items
    items.insert(:name => 'one', :quantity => 3)
    query = items.where(Sequel.|({:id => :$n}, {:quantity => :$n}))
    assert_equal 1, query.call(:select, :n => 3).size
    query.prepare(:select, :replaced)
    assert_equal 1, @db.call(:replaced, :n => 3).size
    items.where(:name => :$name).prepare(:select, :replaced)
    assert_equal [], @db.call(:replaced, :name => 'missing')
  end

  def test_schema_indexes_foreign_keys_and_alter_table
    items = create_items
    items.insert(:name => 'original')
    schema = @db.schema(:items).to_h
    assert_equal :integer, schema[:id][:type]
    assert_equal true, schema[:id][:primary_key]
    assert_equal :boolean, schema[:active][:type]
    assert @db.indexes(:items).values.any?{|i| i[:unique] && i[:columns] == [:name]}
    @db.alter_table(:items){add_column :note, String; rename_column :quantity, :amount}
    @db.alter_table(:items){set_column_default :amount, 42}
    assert_equal 0, items.get(:amount)
    items.insert(:name => 'new')
    assert_equal 42, items.where(:name => 'new').get(:amount)
    @db.alter_table(:items){drop_column :note}
    refute_includes @db.schema(:items).map(&:first), :note
  end

  def test_constraints_and_error_wrapping
    items = create_items
    items.insert(:name => 'one')
    error = assert_raises(Sequel::UniqueConstraintViolation){items.insert(:name => 'one')}
    assert_kind_of Sequel::LibSQL::Native::Error, error.wrapped_exception
    assert_raises(Sequel::NotNullConstraintViolation){items.insert(:name => nil)}
    @db.create_table(:positive){Integer :n; check{n > 0}}
    assert_raises(Sequel::CheckConstraintViolation){@db[:positive].insert(:n => -1)}
    assert_raises(Sequel::DatabaseError){@db.fetch('SELECT no_such_column').all}
    assert_equal 1, items.count
  end

  def test_returning_and_upsert
    items = create_items
    assert_equal [{:id => 1}], items.returning(:id).insert(:name => 'one', :active => true)
    assert_equal [{:quantity => 2}], items.returning(:quantity).update(:quantity => 2)
    items.insert_conflict(:target => :name, :update => {:quantity => 5}).insert(:name => 'one')
    assert_equal 5, items.get(:quantity)
    assert_equal [{:id => 1}], items.returning(:id).delete
  end

  def test_models_associations_and_migrations
    Sequel.extension :migration
    migration = Sequel.migration do
      change do
        create_table(:authors){primary_key :id; String :name; TrueClass :active}
        create_table(:posts){primary_key :id; foreign_key :author_id, :authors; String :title}
      end
    end
    migration.apply(@db, :up)
    author = Class.new(Sequel::Model(@db[:authors]))
    post = Class.new(Sequel::Model(@db[:posts]))
    author.one_to_many :posts, :class => post, :key => :author_id
    post.many_to_one :author, :class => author, :key => :author_id
    person = author.create(:name => 'Francesco', :active => true)
    person.add_post(:title => 'Sequel + Turso')
    assert_equal true, person.refresh.active
    assert_equal 'Sequel + Turso', author.eager(:posts).first.posts.first.title
    assert_equal 'Francesco', post.first.author.name
    person.update(:active => false)
    assert_equal false, person.refresh.active
    migration.apply(@db, :down)
    assert_empty @db.tables
  end

  def test_empty_result_columns_and_batches
    @db.run('CREATE TABLE empty_items (id INTEGER, name TEXT); CREATE INDEX empty_idx ON empty_items(name);')
    assert_equal [:id, :name], @db[:empty_items].columns
    assert_empty @db[:empty_items].all
    assert_equal [:name], @db[:empty_items].select(:name).columns
  end

  def test_logging_and_sqlite_identity
    output = StringIO.new
    @db.loggers << Logger.new(output)
    @db.get(123)
    assert_match(/SELECT 123/, output.string)
    assert_equal :sqlite, @db.database_type
    assert_equal :libsql, @db.adapter_scheme
    assert_operator @db.sqlite_version, :>=, 33500
    assert @db.test_connection
  end

  def test_no_schema_lookup_for_expressions_and_raw_sql
    items = create_items
    items.insert(:name => 'one', :active => true)
    assert_equal 'not a boolean', items.select(Sequel.as('not a boolean', :active)).first[:active]
    assert_equal 1, @db.fetch('SELECT active FROM items').first[:active]
    assert_equal true, @db.fetch('SELECT active FROM items').with_libsql_types(:active => :boolean).first[:active]
    assert_equal true, items.select(Sequel[:active].as(:enabled)).first[:enabled]
  end
end
