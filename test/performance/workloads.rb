# frozen-string-literal: true

module LibSQLPerformance
  Workload = Struct.new(:name, :kind, :units, :prepare, :run, :verify, :iterations, keyword_init: true)

  # Every workload has an untimed correctness check, including affected rows.
  # All writes go to disposable fixture tables; sample setup is never timed.
  class Workloads
    attr_reader :cases, :db

    def initialize(options, rows, batch, workers)
      @options, @rows, @batch, @workers = options, rows, batch, workers
      @db = Sequel.connect(options)
      @cases = []
      create_fixture
      reads
      writes
      connections
    rescue Exception
      @db.disconnect if @db
      raise
    end

    def close
      @db.disconnect
    end

    private

    def add(name, kind, expected, units: 1, prepare: nil, iterations: nil, &block)
      @cases << Workload.new(:name => name, :kind => kind, :units => units,
        :prepare => prepare, :run => block, :iterations => iterations,
        :verify => proc do |value, count|
          valid = expected.respond_to?(:call) ? expected.call(value, count) : value == expected
          raise "Incorrect result for #{name}: #{value.inspect}" unless valid
        end)
    end

    def create_fixture
      @db.run('PRAGMA journal_mode = WAL') unless @options[:database] == ':memory:'
      @db.create_table(:perf_items) do
        primary_key :id
        String :name, :null => false
        Integer :quantity
        TrueClass :active
        Date :day
        DateTime :created_at
        BigDecimal :amount
        File :payload
        index :quantity
      end
      @db.create_table(:perf_writes){primary_key :id; Integer :quantity; String :name, :unique => true}
      @db.create_table(:perf_children){primary_key :id; foreign_key :item_id, :perf_items; index :item_id}
      @items, @writes = @db[:perf_items], @db[:perf_writes]
      @db.transaction do
        @items.import([:id, :name, :quantity, :active, :day, :created_at, :amount, :payload],
          (1..@rows).map{|id| [id, "item-#{id}", id, true, Date.new(2026, 1, 2),
            Time.local(2026, 1, 2, 3, 4, 5), BigDecimal('12.5'), Sequel.blob("\0\xff".b)]})
        @db[:perf_children].import([:item_id], (1..10).map{|id| [id]})
      end
      @db.schema(:perf_items)
      @model = Class.new(Sequel::Model(@items))
      child = Class.new(Sequel::Model(@db[:perf_children]))
      @model.one_to_many :children, :class => child, :key => :item_id
    end

    def reads
      chain = proc{@items.where(:active => true).where(:id => 1).select(:id, :name).order(:id).limit(1)}
      reused = chain.call
      expected = [{:id => 1, :name => 'item-1'}]
      sql = reused.sql
      add('ruby.chain_sql', 'ruby', sql){chain.call.sql}
      add('ruby.reused_sql', 'ruby', sql){reused.sql}
      add('read.chain', 'read', expected){chain.call.all}
      add('read.reused_dataset', 'read', expected){reused.all}
      add('read.raw_sql', 'read', expected){@db.fetch(sql).all}
      add('read.scalar', 'read', 1){@db.get(1)}
      add('read.primary_key', 'read', 'item-1'){@items.where(:id => 1).first[:name]}
      add('read.missing', 'read', nil){@items.where(:id => -1).first}
      add('read.get', 'read', true){@items.where(:id => 1).get(:active)}
      bound = @items.where(:id => :$id).select(:id, :name)
      prepared = bound.prepare(:select, :perf_find)
      add('read.bound_call', 'read', expected){bound.call(:select, :id => 1)}
      add('read.prepared', 'read', expected){prepared.call(:id => 1)}
      add('read.db_call', 'read', expected){@db.call(:perf_find, :id => 1)}
      echo = @db.select(Sequel.as(:$text, :text), Sequel.as(:$number, :number), Sequel.as(:$blob, :blob)).prepare(:first, :perf_echo)
      bound_values = {:text => "quotes ' 世界", :number => -(1 << 63), :blob => Sequel.blob("\0\xff".b)}
      add('read.bound_values', 'read', bound_values){echo.call(bound_values)}
      add('read.narrow_all', 'read', proc{|value, _| value.size == @rows && value.first == {:id => 1, :name => 'item-1'}}, units: @rows) do
        @items.order(:id).select(:id, :name).all
      end
      add('read.typed_all', 'read', proc{|value, _| value.size == @rows && value.first.values_at(:active, :day, :amount, :payload) ==
        [true, Date.new(2026, 1, 2), BigDecimal('12.5'), Sequel.blob("\0\xff".b)] && value.first[:created_at].year == 2026}, units: @rows) do
        @items.order(:id).all
      end
      add('read.each', 'read', @rows * (@rows + 1) / 2, units: @rows) do
        sum = 0
        @items.select(:id).each{|row| sum += row[:id]}
        sum
      end
      add('read.early_break', 'read', 1){@items.order(:id).select(:id).each{|row| break row[:id]}}
      add('read.select_map', 'read', (1..@rows).to_a, units: @rows){@items.order(:id).select_map(:id)}
      add('read.aggregate', 'read', @rows){@items.count}
      add('read.join', 'read', 10, units: 10){@items.join(:perf_children, :item_id => :id).select(Sequel[:perf_items][:id]).all.size}
      add('model.primary_key', 'model', 'item-1'){@model[1].name}
      add('model.all', 'model', proc{|value, _| value.size == @rows && value.first.active == true}, units: @rows){@model.order(:id).all}
      add('model.n_plus_one', 'model', 10, units: 10){@model.where(:id => 1..10).all.sum{|item| item.children.length}}
      add('model.eager', 'model', 10, units: 10){@model.where(:id => 1..10).eager(:children).all.sum{|item| item.children.length}}
      add('schema.cached', 'schema', 8){@db.schema(:perf_items).length}
      add('schema.reload', 'schema', 8){@db.schema(:perf_items, :reload => true).length}
      return unless @options[:adapter] == :libsql

      add('native.pooled_query', 'native', [[1]]) do
        @db.synchronize{|connection| connection.query('SELECT 1'){|result| values = []; result.each{|row| values << row}; values}}
      end
      add('native.bound_query', 'native', [[1]]) do
        @db.synchronize{|connection| connection.query('SELECT ?', [1]){|result| values = []; result.each{|row| values << row}; values}}
      end
    end

    def reset_writes(count = 0)
      @writes.delete
      if count > 0
        @writes.import([:id, :quantity, :name], (1..count).map{|id| [id, 0, "write-#{id}"]})
      end
    end

    def writes
      empty = proc{|_| reset_writes}
      seeded = proc{|count| reset_writes(count)}
      add('write.insert', 'write', proc{|_, count| @writes.count == count}, prepare: empty){@writes.insert(:quantity => 1)}
      insert = @writes.prepare(:insert, :perf_insert, :quantity => :$quantity)
      add('write.bound_insert', 'write', proc{|_, count| @writes.count == count && @writes.get(:quantity) == 1}, prepare: empty){insert.call(:quantity => 1)}
      add('write.update', 'write', proc{|value, count| value == 1 && @writes.where(:quantity => 1).count == count}, prepare: seeded) do |index|
        @writes.where(:id => index + 1).update(:quantity => 1)
      end
      add('write.delete', 'write', proc{|value, _| value == 1 && @writes.empty?}, prepare: seeded){|index| @writes.where(:id => index + 1).delete}
      add('write.returning', 'write', proc{|value, count| value == [{:quantity => 1}] && @writes.count == count}, prepare: empty) do
        @writes.returning(:quantity).insert(:quantity => 1)
      end
      add('write.upsert', 'write', proc{|_, count| @writes.count == 1 && @writes.get(:quantity) == count}, prepare: empty) do |index|
        @writes.insert_conflict(:target => :name, :update => {:quantity => index + 1}).insert(:name => 'upsert', :quantity => 1)
      end
      add('transaction.commit', 'transaction', proc{|_, count| @writes.count == count}, prepare: empty){@db.transaction{@writes.insert(:quantity => 1)}}
      add('transaction.rollback', 'transaction', proc{|_, _| @writes.empty?}, prepare: empty){@db.transaction(:rollback => :always){@writes.insert(:quantity => 1)}}
      add('transaction.savepoint', 'transaction', proc{|_, count| @writes.count == count && @writes.where(:quantity => 2).empty?}, prepare: empty) do
        @db.transaction do
          @writes.insert(:quantity => 1)
          @db.transaction(:savepoint => true, :rollback => :always){@writes.insert(:quantity => 2)}
        end
      end
      bulk_values = Array.new(@batch){[1]}
      batch_sql = Array.new(@batch, 'INSERT INTO perf_writes (quantity) VALUES (1)').join(';')
      check_bulk = proc{|_, count| @writes.count == count * @batch && @writes.sum(:quantity) == count * @batch}
      add('bulk.autocommit_loop', 'bulk', check_bulk, units: @batch, prepare: empty){@batch.times{@writes.insert(:quantity => 1)}}
      add('bulk.transaction_loop', 'bulk', check_bulk, units: @batch, prepare: empty){@db.transaction{@batch.times{@writes.insert(:quantity => 1)}}}
      add('bulk.prepared_transaction_loop', 'bulk', check_bulk, units: @batch, prepare: empty){@db.transaction{@batch.times{insert.call(:quantity => 1)}}}
      add('bulk.import', 'bulk', check_bulk, units: @batch, prepare: empty){@writes.import([:quantity], bulk_values)}
      add('bulk.sql_batch_transaction', 'bulk', check_bulk, units: @batch, prepare: empty){@db.transaction{@db.run(batch_sql)}}
      add('error.unique_constraint', 'error', :caught, prepare: proc{|_| reset_writes(1)}) do
        begin
          @writes.insert(:name => 'write-1')
        rescue Sequel::UniqueConstraintViolation
          :caught
        end
      end
      add('schema.create_drop', 'schema', false) do
        @db.create_table(:perf_ddl){Integer :value}
        @db.drop_table(:perf_ddl)
        @db.table_exists?(:perf_ddl)
      end
    end

    def connections
      add('connection.checkout', 'connection', true){@db.synchronize{|connection| !connection.nil?}}
      add('connection.connect_query_disconnect', 'connection', 1, iterations: 10) do
        connection_db = Sequel.connect(@options)
        begin
          connection_db.get(1)
        ensure
          connection_db.disconnect
        end
      end
      return if @options[:database] == ':memory:'

      add('connection.serial_reads', 'connection', @workers * 10, units: @workers * 10){(@workers * 10).times.sum{@db.get(1)}}
      add('connection.held_pool_reads', 'connection', @workers * 10, units: @workers * 10){@db.synchronize{(@workers * 10).times.sum{@db.get(1)}}}

      # Persistent workers, so thread startup is outside the measured region.
      @jobs = Array.new(@workers){Queue.new}
      @results = Queue.new
      @threads = @jobs.map do |queue|
        Thread.new do
          while queue.pop
            begin
              @results << 10.times.sum{@db.get(1)}
            rescue Exception => error
              @results << error
            end
          end
        end
      end
      add('connection.concurrent_reads', 'connection', @workers * 10, units: @workers * 10) do
        @jobs.each{|queue| queue << true}
        values = @workers.times.map{@results.pop}
        values.each{|value| raise value if value.is_a?(Exception)}
        values.sum
      end
    end

    public

    def stop_workers
      @jobs.each{|queue| queue << false} if @jobs
      @threads.each(&:join) if @threads
    end
  end
end
